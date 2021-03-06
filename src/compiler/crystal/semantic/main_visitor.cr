require "./base_type_visitor"

module Crystal
  class Program
    def visit_main(node, visitor = MainVisitor.new(self))
      node.accept visitor

      fix_empty_types node
      node = cleanup node

      node
    end
  end

  # This is the main visitor of the program, ran after types have been declared
  # and their type declarations (like `@x : Int32`) have been processed.
  #
  # This visits the "main" code of the program and resolves calls, instantiates
  # methods and visits them, recursively, with other MainVisitors.
  #
  # The visitor keeps track of a method's variables (or the main program, split into
  # several files, in case of top-level code). It keeps track both of the type of a
  # variable at a single point (stored in @vars) and the combined type of all assignments
  # to it (in @meta_vars).
  #
  # Call resolution logic is in `Call#recalculate`, where method lookup is done.
  class MainVisitor < BaseTypeVisitor
    property! scope
    getter! typed_def
    property! untyped_def : Def
    getter block : Block?
    property call : Call?
    property type_lookup
    property fun_literal_context : Def | Program | Nil
    property parent : MainVisitor?
    property block_nest : Int32
    property with_scope : Type?

    # These are the free variables that came from matches. We look up
    # here first if we find a single-element Path like `T`.
    property free_vars

    # These are the variables and types that come from a block specification
    # like `&block : Int32 -> Int32`. When doing `yield 1` we need to verify
    # that the yielded expression has the type that the block specification said.
    property yield_vars : Array(Var)?

    # In vars we store the types of variables as we traverse the nodes.
    # These type are not cummulative: if you do `x = 1`, 'x' will have
    # type Int32. Then if you do `x = false`, 'x' will have type Bool.
    getter vars

    # Here we store the cummulative types of variables as we traverse the nodes.
    getter meta_vars : MetaVars

    property is_initialize : Bool

    @unreachable = false
    @is_initialize = false

    @while_stack : Array(While)
    @type_filters : TypeFilters?
    @needs_type_filters : Int32
    @typeof_nest : Int32
    @found_self_in_initialize_call : Array(ASTNode)?
    @used_ivars_in_calls_in_initialize : Hash(String, Array(ASTNode))?
    @block_context : Block?
    @file_module : FileModule?
    @exception_handler_vars : MetaVars?
    @while_vars : MetaVars?

    def initialize(program, vars = MetaVars.new, @typed_def = nil, meta_vars = nil)
      super(program, vars)
      @while_stack = [] of While
      @needs_type_filters = 0
      @unreachable = false
      @typeof_nest = 0
      @is_initialize = !!(typed_def && typed_def.name == "initialize")
      @found_self_in_initialize_call = nil
      @used_ivars_in_calls_in_initialize = nil
      @in_is_a = false

      # We initialize meta_vars from vars given in the constructor.
      # We store those meta vars either in the typed def or in the program
      # so the codegen phase knows the cummulative types to do allocas.
      unless meta_vars
        if typed_def = @typed_def
          meta_vars = typed_def.vars = MetaVars.new
        else
          meta_vars = @program.vars
        end
        vars.each do |name, var|
          meta_var = new_meta_var(name)
          meta_var.bind_to(var)
          meta_vars[name] = meta_var
        end
      end

      @meta_vars = meta_vars
    end

    def untyped_def=(@untyped_def : Nil)
    end

    def visit_any(node)
      @unreachable = false
      super
    end

    def visit(node : FileNode)
      old_vars = @vars
      old_meta_vars = @meta_vars
      old_file_module = @file_module

      @vars = MetaVars.new
      @file_module = file_module = @program.file_module(node.filename)
      @meta_vars = file_module.vars

      node.node.accept self
      node.bind_to node.node

      @vars = old_vars
      @meta_vars = old_meta_vars
      @file_module = old_file_module

      false
    end

    def visit(node : Var)
      var = @vars[node.name]?
      if var
        meta_var = @meta_vars[node.name]
        check_closured meta_var

        if var.nil_if_read?
          meta_var.bind_to(@program.nil_var) unless meta_var.dependencies.try &.any? &.same?(@program.nil_var)
          node.bind_to(@program.nil_var)
        end

        if meta_var.closured?
          var.bind_to(meta_var)
        end

        node.bind_to(var)

        if needs_type_filters?
          @type_filters = TypeFilters.truthy(node)
        end
      elsif node.name == "self"
        current_type = current_type()
        if current_type.is_a?(Program)
          node.raise "there's no self in this scope"
        else
          node.type = current_type.metaclass
        end
      elsif node.special_var?
        special_var = define_special_var(node.name, program.nil_var)
        node.bind_to special_var
      else
        node.raise "read before definition of local variable '#{node.name}'"
      end
    end

    def visit(node : TypeDeclaration)
      case var = node.var
      when Var
        node.raise "declaring the type of a local variable is not yet supported"
      when InstanceVar
        if @untyped_def
          node.raise "declaring the type of an instance variable must be done at the class level"
        end
      when ClassVar
        if @untyped_def
          node.raise "declaring the type of a class variable must be done at the class level"
        end

        attributes = check_valid_attributes node, ValidClassVarAttributes, "class variable"
        class_var = lookup_class_var(var)
        var.var = class_var
        if Attribute.any?(attributes, "ThreadLocal")
          class_var.thread_local = true
        end
      when Global
        if @untyped_def
          node.raise "declaring the type of a global variable must be done at the class level"
        end

        attributes = check_valid_attributes node, ValidGlobalAttributes, "global variable"
        if Attribute.any?(attributes, "ThreadLocal")
          global_var = @program.global_vars[var.name]
          global_var.thread_local = true
        end

        if value = node.value
          type_assign(var, value, node)
          node.bind_to(var)
          return false
        end
      end

      node.type = @program.nil

      false
    end

    def visit(node : UninitializedVar)
      case var = node.var
      when Var
        if @vars[var.name]?
          var.raise "variable '#{var.name}' already declared"
        end

        @in_type_args += 1
        node.declared_type.accept self
        @in_type_args -= 1

        var_type = check_declare_var_type node, node.declared_type.type, "a variable"
        var.type = var_type

        meta_var = @meta_vars[var.name] ||= new_meta_var(var.name)
        if (existing_type = meta_var.type?) && existing_type != var_type
          node.raise "variable '#{var.name}' already declared with type #{existing_type}"
        end

        meta_var.bind_to(var)
        meta_var.freeze_type = var_type

        @vars[var.name] = meta_var

        check_exception_handler_vars(var.name, node)
      when InstanceVar
        type = scope? || current_type
        if @untyped_def
          @in_type_args += 1
          node.declared_type.accept self
          @in_type_args -= 1

          check_declare_var_type node, node.declared_type.type, "an instance variable"
          ivar = lookup_instance_var(var, type)

          if @is_initialize
            @vars[var.name] = MetaVar.new(var.name, ivar.type)
          end
        else
          # Already handled in a previous visitor
          node.type = @program.nil
          return false
        end

        case type
        when NonGenericClassType
          @in_type_args += 1
          node.declared_type.accept self
          @in_type_args -= 1
          check_declare_var_type node, node.declared_type.type, "an instance variable"
        when GenericClassType
          # OK
        when GenericClassInstanceType
          # OK
        else
          node.raise "can only declare instance variables of a non-generic class, not a #{type.type_desc} (#{type})"
        end
      when ClassVar
        attributes = check_valid_attributes node, ValidGlobalAttributes, "global variable"

        class_var = visit_class_var var
        class_var.thread_local = true if Attribute.any?(attributes, "ThreadLocal")
      end

      node.type = @program.nil

      false
    end

    def check_exception_handler_vars(var_name, node)
      # If inside a begin part of an exception handler, bind this type to
      # the variable that will be used in the rescue/else blocks.
      if exception_handler_vars = @exception_handler_vars
        var = (exception_handler_vars[var_name] ||= MetaVar.new(var_name))
        var.bind_to(node)
      end
    end

    def visit(node : Out)
      case exp = node.exp
      when Var
        if @meta_vars.has_key?(exp.name)
          exp.raise "variable '#{exp.name}' is already defined, `out` must be used to define a variable, use another name"
        end

        # We declare out variables
        @meta_vars[exp.name] = new_meta_var(exp.name)
        @vars[exp.name] = new_meta_var(exp.name)
      when InstanceVar
        var = lookup_instance_var exp
        exp.bind_to(var)

        if @is_initialize
          @vars[exp.name] = MetaVar.new(exp.name)
        end
      when Underscore
        # Nothing to do
      else
        node.raise "Bug: unexpected out exp: #{exp}"
      end

      node.bind_to node.exp

      false
    end

    def visit(node : Global)
      # Reading from a special global variable is actually
      # reading from a local variable with that same not,
      # invoking `not_nil!` on it (because these are usually
      # accessed after invoking a method that brought them
      # into the current scope, and it would be annoying
      # to ask the user to always invoke `not_nil!` on it)
      case node.name
      when "$~", "$?"
        expanded = Call.new(Var.new(node.name).at(node), "not_nil!").at(node)
        expanded.accept self
        node.bind_to expanded
        node.expanded = expanded
        return false
      end

      visit_global node
      false
    end

    def visit_global(node)
      var = lookup_global_variable(node)

      if first_time_accessing_meta_type_var?(var)
        var_type = var.type?
        if var_type && !var_type.includes_type?(program.nil)
          node.raise "global variable '#{node.name}' is read here before it was initialized, rendering it nilable, but its type is #{var_type}"
        end
        var.bind_to program.nil_var
      end

      node.bind_to var
      node.var = var
      var
    end

    def lookup_global_variable(node)
      var = program.global_vars[node.name]?
      undefined_global_variable(node) unless var
      var
    end

    def undefined_global_variable(node)
      similar_name = lookup_similar_global_variable_name(node)
      program.undefined_global_variable(node, similar_name)
    end

    def undefined_instance_variable(owner, node)
      similar_name = lookup_similar_instance_variable_name(node, owner)
      program.undefined_instance_variable(node, owner, similar_name)
    end

    def lookup_similar_instance_variable_name(node, owner)
      case owner
      when NonGenericModuleType, GenericClassType, GenericModuleType
        return nil
      end

      Levenshtein.find(node.name) do |finder|
        owner.all_instance_vars.each_key do |name|
          finder.test(name)
        end
      end
    end

    def lookup_similar_global_variable_name(node)
      Levenshtein.find(node.name) do |finder|
        program.global_vars.each_key do |name|
          finder.test(name)
        end
      end
    end

    def first_time_accessing_meta_type_var?(var)
      return false if var.uninitialized?

      if var.freeze_type
        deps = var.dependencies?
        # If no dependencies it's the case of a global for a regex literal.
        # If there are dependencies and it's just one, it's the same var
        deps ? deps.size == 1 : false
      else
        !var.dependencies?
      end
    end

    def visit(node : InstanceVar)
      var = lookup_instance_var node
      node.bind_to(var)

      if @is_initialize && !@vars.has_key?(node.name) && !scope.has_instance_var_initializer?(node.name)
        ivar = scope.lookup_instance_var(node.name)
        ivar.nil_reason ||= NilReason.new(node.name, :used_before_initialized, [node] of ASTNode)
        ivar.bind_to program.nil_var
      end
    end

    def visit(node : ReadInstanceVar)
      visit_read_instance_var node
      false
    end

    def visit_read_instance_var(node)
      node.visitor = self
      node.obj.accept self
      node.obj.add_observer node
      node.update
    end

    def visit(node : ClassVar)
      attributes = check_valid_attributes node, ValidGlobalAttributes, "global variable"

      var = visit_class_var node
      var.thread_local = true if Attribute.any?(attributes, "ThreadLocal")

      false
    end

    def visit_class_var(node)
      var = lookup_class_var(node)
      node.bind_to var
      node.var = var
      var
    end

    def lookup_instance_var(node)
      lookup_instance_var node, @scope.try(&.remove_typedef)
    end

    def lookup_instance_var(node, scope)
      case scope
      when Nil
        node.raise "can't use instance variables at the top level"
      when Program
        node.raise "can't use instance variables at the top level"
      when PrimitiveType
        node.raise "can't use instance variables inside primitive types (at #{scope})"
      when EnumType
        node.raise "can't use instance variables inside enums (at enum #{scope})"
      when .metaclass?
        node.raise "@instance_vars are not yet allowed in metaclasses: use @@class_vars instead"
      when InstanceVarContainer
        var_with_owner = scope.lookup_instance_var_with_owner?(node.name)
        unless var_with_owner
          undefined_instance_variable(scope, node)
        end
        if !var_with_owner.instance_var.type?
          undefined_instance_variable(scope, node)
        end
        check_self_closured
        var_with_owner.instance_var
      else
        node.raise "Bug: #{scope} is not an InstanceVarContainer"
      end
    end

    def end_visit(node : Expressions)
      node.bind_to node.last unless node.empty?
    end

    def visit(node : Assign)
      type_assign node.target, node.value, node

      if @is_initialize && !@found_self_in_initialize_call
        value = node.value
        if value.is_a?(Var) && value.name == "self"
          @found_self_in_initialize_call = [value] of ASTNode
        end
      end
      false
    end

    def type_assign(target : Var, value, node)
      value.accept self

      target.bind_to value
      node.bind_to value

      var_name = target.name

      value_type_filters = @type_filters
      @type_filters = nil

      meta_var = (@meta_vars[var_name] ||= new_meta_var(var_name))

      begin
        meta_var.bind_to value
      rescue ex : FrozenTypeException
        target.raise ex.message
      end

      meta_var.assigned_to = true
      check_closured meta_var

      simple_var = MetaVar.new(var_name)
      simple_var.bind_to(target)

      if meta_var.closured?
        simple_var.bind_to(meta_var)
      end

      @vars[var_name] = simple_var

      check_exception_handler_vars var_name, value

      if needs_type_filters?
        @type_filters = TypeFilters.and(TypeFilters.truthy(target), value_type_filters)
      end

      if target.special_var?
        if typed_def = @typed_def
          typed_def.add_special_var(target.name)

          # Always bind with a special var with nil, so it's easier to assign it later
          # in the codegen (just store the whole value through a pointer)
          simple_var.bind_to(@program.nil_var)
          meta_var.bind_to(@program.nil_var)

          # If we are in a call's block, define the special var in the block
          if (call = @call) && call.block
            call.parent_visitor.define_special_var(target.name, value)
          end
        else
          node.raise "'#{var_name}' can't be assigned at the top level"
        end
      end
    end

    def type_assign(target : InstanceVar, value, node)
      # Check if this is an instance variable initializer
      unless @scope
        # Already handled by InstanceVarsInitializerVisitor
        return
      end

      value.accept self

      var = lookup_instance_var target

      target.bind_to var
      node.bind_to value

      begin
        var.bind_to value
      rescue ex : FrozenTypeException
        target.raise ex.message
      end

      if @is_initialize
        var_name = target.name

        meta_var = (@meta_vars[var_name] ||= new_meta_var(var_name))
        meta_var.bind_to value
        meta_var.assigned_to = true

        simple_var = MetaVar.new(var_name)
        simple_var.bind_to(target)

        used_ivars_in_calls_in_initialize = @used_ivars_in_calls_in_initialize
        if (found_self = @found_self_in_initialize_call) || (used_ivars_node = used_ivars_in_calls_in_initialize.try(&.[var_name]?)) || (@block_nest > 0 && !@vars.has_key?(var_name))
          ivar = scope.lookup_instance_var(var_name)
          if found_self
            ivar.nil_reason = NilReason.new(var_name, :used_self_before_initialized, found_self)
          else
            ivar.nil_reason = NilReason.new(var_name, :used_before_initialized, used_ivars_node)
          end
          ivar.bind_to program.nil_var
        end

        @vars[var_name] = simple_var

        check_exception_handler_vars var_name, value
      end
    end

    def type_assign(target : Path, value, node)
      false
    end

    def type_assign(target : Global, value, node)
      attributes = check_valid_attributes target, ValidGlobalAttributes, "global variable"

      value.accept self

      var = lookup_global_variable(target)

      # If we are assigning to a global inside a method, make it nilable
      # if this is the first time we are assigning to it, because
      # the method might be called conditionally
      if @typed_def && first_time_accessing_meta_type_var?(var)
        var.bind_to program.nil_var
      end

      var.thread_local = true if Attribute.any?(attributes, "ThreadLocal")
      target.var = var

      target.bind_to var

      node.bind_to value
      var.bind_to value
    end

    def type_assign(target : ClassVar, value, node)
      attributes = check_valid_attributes target, ValidClassVarAttributes, "class variable"

      # Outside a def is already handled by ClassVarsInitializerVisitor
      # (@exp_nest is 1 if we are at the top level because it was incremented
      # by one since we are inside an Assign)
      if !@typed_def && (@exp_nest <= 1) && !inside_block?
        var = lookup_class_var(target)
        check_class_var_is_thread_local(target, var, attributes)
        return
      end

      value.accept self

      var = lookup_class_var(target)
      check_class_var_is_thread_local(target, var, attributes)

      target.bind_to var

      node.bind_to value
      var.bind_to value
    end

    def check_class_var_is_thread_local(target, var, attributes)
      var.thread_local = true if Attribute.any?(attributes, "ThreadLocal")
      target.var = var
    end

    def type_assign(target : Underscore, value, node)
      value.accept self
      node.bind_to value
    end

    def type_assign(target, value, node)
      raise "Bug: unknown assign target in MainVisitor: #{target}"
    end

    def visit(node : Def)
      check_outside_block_or_exp node, "declare def"

      node.runtime_initializers.try &.each &.accept self

      false
    end

    def visit(node : Macro)
      check_outside_block_or_exp node, "declare macro"

      false
    end

    def visit(node : Yield)
      call = @call
      unless call
        node.raise "can't use `yield` outside a method"
      end

      if ctx = @fun_literal_context
        node.raise <<-MSG
          can't use `yield` inside a proc literal or captured block

          Make sure to read the whole docs section about blocks and procs,
          including "Capturing blocks" and "Block forwarding":

          http://crystal-lang.org/docs/syntax_and_semantics/blocks_and_procs.html
          MSG
      end

      block = call.block || node.raise("no block given")

      # This is the case of a yield when there's a captured block
      if block.fun_literal
        block_arg_name = typed_def.block_arg.not_nil!.name
        block_var = Var.new(block_arg_name).at(node.location)
        call = Call.new(block_var, "call", node.exps).at(node.location)
        call.accept self
        node.bind_to call
        node.expanded = call
        return false
      end

      node.scope.try &.accept self
      node.exps.each &.accept self

      # We use a binder to support splats and other complex forms
      binder = block.binder ||= YieldBlockBinder.new(@program, block)
      binder.add_yield(node, @yield_vars)
      binder.update

      unless block.visited?
        # When we yield, we are no longer inside `untyped_def`, so we un-nest
        untyped_def = @untyped_def
        untyped_def.block_nest -= 1 if untyped_def

        call.bubbling_exception do
          if node_scope = node.scope
            block.scope = node_scope.type
          end
          ignoring_type_filters do
            block.accept call.parent_visitor.not_nil!
          end
        end

        # And now we are back inside `untyped_def`
        untyped_def.block_nest += 1 if untyped_def
      end

      node.bind_to block

      @type_filters = nil
      false
    end

    def visit(node : Block)
      return if node.visited?

      node.visited = true
      node.context = current_non_block_context

      before_block_vars = node.vars.try(&.dup) || MetaVars.new

      arg_counter = 0
      body_exps = node.body.as?(Expressions).try(&.expressions)

      meta_vars = @meta_vars.dup
      node.args.each do |arg|
        # The parser generates __argN block arguments for tuple unpacking,
        # and they need a special treatment because they shouldn't override
        # local variables. So we search the unpacked vars in the body.
        if arg.name.starts_with?("__arg") && body_exps
          while arg_counter < body_exps.size &&
                (assign = body_exps[arg_counter]).is_a?(Assign) &&
                (target = assign.target).is_a?(Var) &&
                (call = assign.value).is_a?(Call) &&
                (call_var = call.obj).is_a?(Var) &&
                call_var.name == arg.name
            bind_block_var(node, target, meta_vars, before_block_vars)
            arg_counter += 1
          end
        end

        bind_block_var(node, arg, meta_vars, before_block_vars)
      end

      @block_nest += 1

      block_visitor = MainVisitor.new(program, before_block_vars, @typed_def, meta_vars)
      block_visitor.yield_vars = @yield_vars
      block_visitor.free_vars = @free_vars
      block_visitor.untyped_def = @untyped_def
      block_visitor.call = @call
      block_visitor.fun_literal_context = @fun_literal_context
      block_visitor.parent = self
      block_visitor.with_scope = node.scope || with_scope

      block_scope = @scope
      block_scope ||= current_type.metaclass unless current_type.is_a?(Program)

      block_visitor.scope = block_scope

      block_visitor.block = node
      block_visitor.type_lookup = type_lookup || current_type
      block_visitor.block_nest = @block_nest

      node.body.accept block_visitor

      @block_nest -= 1

      # Check re-assigned variables and bind them.
      bind_vars block_visitor.vars, node.vars
      bind_vars block_visitor.vars, node.after_vars, node.args

      # Special vars, even if only assigned inside a block,
      # must be inside the def's metavars.
      meta_vars.each do |name, var|
        if var.special_var?
          define_special_var(name, var)
        end
      end

      node.vars = meta_vars

      node.bind_to node.body

      false
    end

    def bind_block_var(node, target, meta_vars, before_block_vars)
      meta_var = new_meta_var(target.name, context: node)
      meta_var.bind_to(target)
      meta_vars[target.name] = meta_var

      before_block_var = new_meta_var(target.name, context: node)
      before_block_var.bind_to(target)
      before_block_vars[target.name] = before_block_var
    end

    def bind_vars(from_vars, to_vars, ignored = nil)
      if to_vars
        from_vars.each do |name, block_var|
          unless ignored.try &.find { |arg| arg.name == name }
            to_var = to_vars[name]?
            if to_var && !to_var.same?(block_var)
              to_var.try &.bind_to(block_var)
            end
          end
        end
      end
    end

    def visit(node : ProcLiteral)
      return false if node.type?

      fun_vars = @vars.dup
      meta_vars = @meta_vars.dup

      node.def.args.each do |arg|
        # It can happen that the argument has a type already,
        # when converting a block to a proc literal
        if restriction = arg.restriction
          restriction.accept self
          arg_type = restriction.type.instance_type
          MainVisitor.check_type_allowed_as_proc_argument(node, arg_type)
          arg.type = arg_type.virtual_type
        elsif !arg.type?
          arg.raise "function argument '#{arg.name}' must have a type"
        end

        fun_var = MetaVar.new(arg.name, arg.type)
        fun_vars[arg.name] = fun_var

        meta_var = new_meta_var(arg.name, context: node.def)
        meta_var.bind_to fun_var
        meta_vars[arg.name] = meta_var
      end

      node.bind_to node.def
      node.def.bind_to node.def.body
      node.def.vars = meta_vars

      block_visitor = MainVisitor.new(program, fun_vars, node.def, meta_vars)
      block_visitor.types = @types
      block_visitor.yield_vars = @yield_vars
      block_visitor.free_vars = @free_vars
      block_visitor.untyped_def = node.def
      block_visitor.call = @call
      block_visitor.scope = @scope
      block_visitor.type_lookup = type_lookup
      block_visitor.fun_literal_context = @fun_literal_context || @typed_def || @program
      block_visitor.block_nest = @block_nest + 1
      block_visitor.parent = self
      block_visitor.is_initialize = @is_initialize

      node.def.body.accept block_visitor

      false
    end

    def self.check_type_allowed_as_proc_argument(node, type)
      Crystal.check_type_allowed_in_generics(node, type, "cannot be used as a Proc argument type")
    end

    def visit(node : ProcPointer)
      return false if node.call?

      obj = node.obj

      if obj
        obj.accept self
      end

      call = Call.new(obj, node.name)
      prepare_call(call)

      # Check if it's ->LibFoo.foo, so we deduce the type from that method
      if node.args.empty? && obj && (obj_type = obj.type).is_a?(LibType)
        matching_fun = obj_type.lookup_first_def(node.name, false)
        node.raise "undefined fun '#{node.name}' for #{obj_type}" unless matching_fun

        call.args = matching_fun.args.map_with_index do |arg, i|
          Var.new("arg#{i}", arg.type.instance_type).as(ASTNode)
        end
      else
        call.args = node.args.map_with_index do |arg, i|
          arg.accept self
          arg_type = arg.type.instance_type
          MainVisitor.check_type_allowed_as_proc_argument(node, arg_type)
          Var.new("arg#{i}", arg_type.virtual_type).as(ASTNode)
        end
      end

      begin
        call.recalculate
      rescue ex : Crystal::Exception
        node.raise "error instantiating #{node}", ex
      end

      node.call = call
      node.bind_to call

      false
    end

    def visit(node : Call)
      prepare_call(node)

      if expand_macro(node)
        # It can happen that this call is inside an ArrayLiteral or HashLiteral,
        # was expanded but isn't bound to the expansion because the call (together
        # with its expantion) was cloned.
        if (expanded = node.expanded) && !node.dependencies?
          node.bind_to(expanded)
        end
        return false
      end

      # If the call has splats or double splats, and any of them are
      # not variables, instance variables or global variables,
      # we replace this call with a separate one that declares temporary
      # variables with this splat expressions, so we don't evaluate them
      # twice (#2677)
      if call_needs_splat_expansion?(node)
        return replace_call_splats(node)
      end

      obj = node.obj
      args = node.args
      block_arg = node.block_arg
      named_args = node.named_args

      ignoring_type_filters do
        if obj
          obj.accept(self)

          check_lib_call node, obj.type?

          if check_special_new_call(node, obj.type?)
            return false
          end
        end

        args.each &.accept(self)
        block_arg.try &.accept self
        named_args.try &.each &.value.accept self
      end

      obj.try &.add_input_observer(node)
      args.each &.add_input_observer(node)
      block_arg.try &.add_input_observer node
      named_args.try &.each &.value.add_input_observer(node)

      check_super_in_initialize node

      # If the call has a block we need to create a copy of the variables
      # and bind them to the current variables. Then, when visiting
      # the block we will bind more variables to these ones if variables
      # are reassigned.
      if node.block || block_arg
        before_vars = MetaVars.new
        after_vars = MetaVars.new

        @vars.each do |name, var|
          before_var = MetaVar.new(name)
          before_var.bind_to(var)
          before_var.nil_if_read = var.nil_if_read?
          before_vars[name] = before_var

          after_var = MetaVar.new(name)
          after_var.bind_to(var)
          after_var.nil_if_read = var.nil_if_read?
          after_vars[name] = after_var
          @vars[name] = after_var
        end

        if block = node.block
          block.vars = before_vars
          block.after_vars = after_vars
        else
          node.before_vars = before_vars
        end
      end

      node.recalculate

      check_call_in_initialize node

      @type_filters = nil
      @unreachable = true if node.no_returns?

      false
    end

    def prepare_call(node)
      if node.global?
        node.scope = @program
      else
        node.scope = @scope || current_type.metaclass
      end
      node.with_scope = with_scope
      node.parent_visitor = self
    end

    def call_needs_splat_expansion?(node)
      node.args.each do |arg|
        case arg
        when Splat
          exp = arg.exp
        when DoubleSplat
          exp = arg.exp
        else
          next
        end

        case exp
        when Var, InstanceVar, ClassVar, Global
          next
        end

        return true
      end

      false
    end

    def replace_call_splats(node)
      expanded = node.clone

      exps = [] of ASTNode
      expanded.args.each do |arg|
        case arg
        when Splat
          exp = arg.exp
        when DoubleSplat
          exp = arg.exp
        else
          next
        end

        case exp
        when Var, InstanceVar, ClassVar, Global
          next
        end

        temp_var = @program.new_temp_var.at(arg.location)
        assign = Assign.new(temp_var, exp).at(arg.location)
        exps << assign
        case arg
        when Splat
          arg.exp = temp_var.clone.at(arg.location)
        when DoubleSplat
          arg.exp = temp_var.clone.at(arg.location)
        else
          next
        end
      end

      exps << expanded
      expansion = Expressions.from(exps)
      expansion.accept self
      node.expanded = expansion
      node.bind_to(expanded)
      return false
    end

    # If it's a super call inside an initialize we treat
    # set instance vars from superclasses to not-nil
    def check_super_in_initialize(node)
      if @is_initialize && node.name == "super" && !node.obj
        superclass_vars = scope.all_instance_vars.keys - scope.instance_vars.keys
        superclass_vars.each do |name|
          instance_var = scope.lookup_instance_var(name)

          # If a variable was used before this supercall, it becomes nilable
          if @used_ivars_in_calls_in_initialize.try &.has_key?(name)
            instance_var.nil_reason ||= NilReason.new(name, :used_before_initialized, [node] of ASTNode)
            instance_var.bind_to @program.nil_var
          else
            # Otherwise, declare it as a "local" variable
            meta_var = MetaVar.new(name)
            meta_var.bind_to instance_var
            @vars[name] = meta_var
          end
        end
      end
    end

    # Check if it's a call to self. In that case, all instance variables
    # not mentioned so far will be considered nil.
    def check_call_in_initialize(node)
      return unless @is_initialize
      return if @typeof_nest > 0

      node_obj = node.obj
      if !node_obj || (node_obj.is_a?(Var) && node_obj.name == "self")
        # Special case: when calling self.class a class method will be invoked
        # and there's no possibility of accessing instance vars, so we ignore this case.
        if node.name == "class" && node.args.empty?
          return
        end

        ivars, found_self = gather_instance_vars_read node
        if found_self
          @found_self_in_initialize_call ||= found_self
        elsif ivars
          used_ivars_in_calls_in_initialize = @used_ivars_in_calls_in_initialize
          if used_ivars_in_calls_in_initialize
            @used_ivars_in_calls_in_initialize = used_ivars_in_calls_in_initialize.merge(ivars)
          else
            @used_ivars_in_calls_in_initialize = ivars
          end
        end
      else
        # Check if any argument is "self"
        unless @found_self_in_initialize_call
          node.args.each do |arg|
            if arg.is_a?(Var) && arg.name == "self"
              @found_self_in_initialize_call = [node] of ASTNode
              return
            end
          end
        end
      end
    end

    # Fill function literal argument types for C functions
    def check_lib_call(node, obj_type)
      return unless obj_type.is_a?(LibType)

      # Error quickly if we can't find a fun
      method = obj_type.lookup_first_def(node.name, false)
      node.raise "undefined fun '#{node.name}' for #{obj_type}" unless method

      node.args.each_with_index do |arg, index|
        case arg
        when ProcLiteral
          next unless arg.def.args.any? { |def_arg| !def_arg.restriction && !def_arg.type? }

          check_lib_call_arg(method, index) do |method_arg_type|
            arg.def.args.each_with_index do |def_arg, def_arg_index|
              if !def_arg.restriction && !def_arg.type?
                def_arg.type = method_arg_type.arg_types[def_arg_index]?
              end
            end
          end
        when ProcPointer
          next unless arg.args.empty?

          check_lib_call_arg(method, index) do |method_arg_type|
            method_arg_type.arg_types.each do |arg_type|
              arg.args.push TypeNode.new(arg_type)
            end
          end
        end
      end
    end

    def check_lib_call_arg(method, arg_index)
      method_arg = method.args[arg_index]?
      return unless method_arg

      method_arg_type = method_arg.type
      return unless method_arg_type.is_a?(ProcInstanceType)

      yield method_arg_type
    end

    # Check if it's ProcType#new
    def check_special_new_call(node, obj_type)
      return false unless obj_type
      return false unless obj_type.metaclass?

      instance_type = obj_type.instance_type.remove_typedef

      if node.name == "new"
        case instance_type
        when ProcInstanceType
          return special_proc_type_new_call(node, instance_type)
        when CStructOrUnionType
          if named_args = node.named_args
            return special_struct_or_union_new_with_named_args(node, instance_type, named_args)
          end
        end
      end

      false
    end

    def special_proc_type_new_call(node, proc_type)
      if node.args.size != 0
        return false
      end

      block = node.block
      unless block
        return false
      end

      if block.args.size > proc_type.arg_types.size
        node.wrong_number_of "block arguments", "#{proc_type}#new", block.args.size, proc_type.arg_types.size
      end

      # We create a ->(...) { } from the block
      proc_args = proc_type.arg_types.map_with_index do |arg_type, index|
        block_arg = block.args[index]?
        Arg.new(block_arg.try(&.name) || @program.new_temp_var_name, type: arg_type)
      end

      expected_return_type = proc_type.return_type
      expected_return_type = @program.nil if expected_return_type.void?

      proc_def = Def.new("->", proc_args, block.body)
      proc_literal = ProcLiteral.new(proc_def).at(node.location)
      proc_literal.expected_return_type = expected_return_type
      proc_literal.force_nil = true if expected_return_type.nil_type?
      proc_literal.accept self

      node.bind_to proc_literal
      node.expanded = proc_literal

      true
    end

    # Rewrite:
    #
    #     LibFoo::Struct.new arg0: value0, argN: value0
    #
    # To:
    #
    #   temp = LibFoo::Struct.new
    #   temp.arg0 = value0
    #   temp.argN = valueN
    #   temp
    def special_struct_or_union_new_with_named_args(node, type, named_args)
      exps = [] of ASTNode

      temp_name = @program.new_temp_var_name

      new_call = Call.new(node.obj, "new").at(node.location)

      new_assign = Assign.new(Var.new(temp_name), new_call)
      exps << new_assign

      named_args.each do |named_arg|
        assign_call = Call.new(Var.new(temp_name), "#{named_arg.name}=", named_arg.value)
        if loc = named_arg.location
          assign_call.location = loc
          assign_call.name_column_number = loc.column_number
        end
        exps << assign_call
      end

      exps << Var.new(temp_name)

      expanded = Expressions.new(exps)
      expanded.accept self

      node.bind_to expanded
      node.expanded = expanded

      true
    end

    class InstanceVarsCollector < Visitor
      getter ivars : Hash(String, Array(ASTNode))?
      getter found_self : Array(ASTNode)?
      @scope : Type
      @in_super : Int32
      @callstack : Array(ASTNode)
      @visited : Set(UInt64)?
      @vars : MetaVars

      def initialize(a_def, @scope, @vars)
        @found_self = nil
        @in_super = 0
        @callstack = [a_def] of ASTNode
      end

      def node_in_callstack(node)
        nodes = [] of ASTNode
        nodes.concat @callstack
        nodes.push node
        nodes
      end

      def visit(node : InstanceVar)
        unless @vars.has_key?(node.name)
          ivars = @ivars ||= Hash(String, Array(ASTNode)).new
          unless ivars.has_key?(node.name)
            ivars[node.name] = node_in_callstack(node)
          end
        end
      end

      def visit(node : Var)
        if @in_super == 0 && node.name == "self"
          @found_self = node_in_callstack(node)
        end
        false
      end

      def visit(node : Assign)
        node.value.accept self
        false
      end

      def visit(node : Call)
        obj = node.obj

        # Skip class method
        if obj.is_a?(Var) && obj.name == "self" && node.name == "class" && node.args.empty?
          return false
        end

        visited = @visited

        node.target_defs.try &.each do |target_def|
          if target_def.owner == @scope
            next if visited.try &.includes?(target_def.object_id)

            visited = @visited ||= Set(typeof(object_id)).new
            visited << target_def.object_id

            @callstack.push(node)
            target_def.body.accept self
            @callstack.pop
          end
        end

        if node.name == "super"
          @in_super += 1
        end

        true
      end

      def end_visit(node : Call)
        if node.name == "super"
          @in_super -= 1
        end
      end

      def visit(node : ASTNode)
        true
      end
    end

    def gather_instance_vars_read(node)
      collector = InstanceVarsCollector.new(typed_def, scope, @vars)
      node.accept collector
      {collector.ivars, collector.found_self}
    end

    def visit(node : Return)
      typed_def = @typed_def || node.raise("can't return from top level")

      if typed_def.captured_block?
        node.raise "can't return from captured block, use next"
      end

      node.exp.try &.accept self

      node.target = typed_def

      typed_def.bind_to(node.exp || program.nil_var)
      @unreachable = true

      false
    end

    def end_visit(node : Splat)
      node.bind_to node.exp
    end

    def end_visit(node : DoubleSplat)
      node.bind_to node.exp
    end

    def visit(node : Underscore)
      if @in_type_args == 0
        node.raise "can't read from _"
      else
        node.raise "can't use underscore as generic type argument"
      end
    end

    def visit(node : IsA)
      node.obj.accept self

      @in_type_args += 1
      @in_is_a = true
      node.const.accept self
      @in_is_a = false
      @in_type_args -= 1

      node.type = program.bool
      const = node.const

      # When doing x.is_a?(A) and A turns out to be a constant (not a type),
      # replace it with a === comparison. Most usually this happens in a case expression.
      if const.is_a?(Path) && const.target_const
        comp = Call.new(const, "===", node.obj).at(node.location)
        comp.accept self
        node.syntax_replacement = comp
        node.bind_to comp
        return
      end

      if needs_type_filters? && (var = get_expression_var(node.obj))
        @type_filters = TypeFilters.new var, SimpleTypeFilter.new(node.const.type)
      end

      false
    end

    def end_visit(node : RespondsTo)
      node.type = program.bool
      if needs_type_filters? && (var = get_expression_var(node.obj))
        @type_filters = TypeFilters.new var, RespondsToTypeFilter.new(node.name)
      end
    end

    # Get the variable of an expression.
    # If it's a variable, it's that variable.
    # If it's an assignment to a variable, it's that variable.
    def get_expression_var(exp)
      case exp
      when Var
        return exp
      when Assign
        target = exp.target
        return target if target.is_a?(Var)
      end
      nil
    end

    def visit(node : Cast | NilableCast)
      node.obj.accept self

      @in_type_args += 1
      node.to.accept self
      @in_type_args -= 1

      case node.to.type?
      when @program.object
        node.raise "can't cast to Object yet"
      when @program.reference
        node.raise "can't cast to Reference yet"
      when @program.class_type
        node.raise "can't cast to Class yet"
      end

      obj_type = node.obj.type?
      if obj_type.is_a?(PointerInstanceType)
        to_type = node.to.type.instance_type
        if to_type.is_a?(GenericType)
          node.raise "can't cast #{obj_type} to #{to_type}"
        end
      end

      node.obj.add_observer node
      node.update

      false
    end

    def visit(node : ClassDef)
      check_outside_block_or_exp node, "declare class"

      pushing_type(node.resolved_type) do
        node.runtime_initializers.try &.each &.accept self
        node.body.accept self
      end

      false
    end

    def visit(node : ModuleDef)
      check_outside_block_or_exp node, "declare module"

      pushing_type(node.resolved_type) do
        node.body.accept self
      end

      false
    end

    def visit(node : Alias)
      check_outside_block_or_exp node, "declare alias"

      false
    end

    def visit(node : Include)
      check_outside_block_or_exp node, "include"

      node.runtime_initializers.try &.each &.accept self

      false
    end

    def visit(node : Extend)
      check_outside_block_or_exp node, "extend"

      node.runtime_initializers.try &.each &.accept self

      false
    end

    def visit(node : LibDef)
      check_outside_block_or_exp node, "declare lib"

      @attributes = nil
      pushing_type(node.resolved_type) do
        node.body.accept self
      end

      false
    end

    def visit(node : StructDef)
      false
    end

    def visit(node : UnionDef)
      false
    end

    def visit(node : TypeDef)
      false
    end

    def visit(node : FunDef)
      return false unless node.body

      visit_fun_def(node)
    end

    def visit(node : EnumDef)
      check_outside_block_or_exp node, "declare enum"

      pushing_type(node.resolved_type) do
        node.members.each &.accept self
      end

      false
    end

    def visit(node : Arg)
      false
    end

    def visit(node : If)
      request_type_filters do
        node.cond.accept self
      end

      cond_type_filters = @type_filters
      cond_vars = @vars

      @type_filters = nil
      @vars = cond_vars.dup
      @unreachable = false

      filter_vars cond_type_filters

      node.then.accept self

      then_vars = @vars
      then_type_filters = @type_filters
      @type_filters = nil
      then_unreachable = @unreachable

      @vars = cond_vars.dup
      @unreachable = false

      # The only cases where we can deduce something for the 'else'
      # block is when the condition is a Var (in the else it must be
      # nil), IsA (in the else it's not that type), RespondsTo
      # (in the else it doesn't respond to that message) or Not.
      case node.cond
      when Var, IsA, RespondsTo, Not
        filter_vars cond_type_filters, &.not
      end

      node.else.accept self

      else_vars = @vars
      else_type_filters = @type_filters
      @type_filters = nil
      else_unreachable = @unreachable

      merge_if_vars node, cond_vars, then_vars, else_vars, then_unreachable, else_unreachable

      if needs_type_filters?
        if node.and?
          @type_filters = TypeFilters.and(cond_type_filters, then_type_filters, else_type_filters)
          # TODO: or type filters
          # elsif node.or?
          #   node.type_filters = or_type_filters(node.then.type_filters, node.else.type_filters)
        end
      end

      @unreachable = then_unreachable && else_unreachable

      node.bind_to [node.then, node.else]

      false
    end

    # Here we merge the variables from both branches of an if.
    # We basically:
    #   - Create a variable whose type is the merged types of the last
    #     type of each branch.
    #   - Make the variable nilable if the variable wasn't declared
    #     before the 'if' and it doesn't appear in one of the branches.
    #   - Don't use the type of a branch that is unreachable (ends with return,
    #     break or with a call that is NoReturn)
    def merge_if_vars(node, cond_vars, then_vars, else_vars, then_unreachable, else_unreachable)
      all_vars_names = Set(String).new
      then_vars.each_key do |name|
        all_vars_names << name
      end
      else_vars.each_key do |name|
        all_vars_names << name
      end

      all_vars_names.each do |name|
        cond_var = cond_vars[name]?
        then_var = then_vars[name]?
        else_var = else_vars[name]?

        # Check whether the var didn't change at all
        next if then_var.same?(else_var)

        if_var = MetaVar.new(name)
        if_var.nil_if_read = !!(then_var.try(&.nil_if_read?) || else_var.try(&.nil_if_read?))

        if then_var && else_var
          if then_unreachable
            if_var.bind_to conditional_no_return(node.then, then_var)
          else
            if_var.bind_to then_var
          end

          if else_unreachable
            if_var.bind_to conditional_no_return(node.else, else_var)
          else
            if_var.bind_to else_var
          end
        elsif then_var
          if then_unreachable
            if_var.bind_to conditional_no_return(node.then, then_var)
          else
            if_var.bind_to then_var
          end

          if cond_var
            if_var.bind_to cond_var
          elsif !else_unreachable
            if_var.bind_to program.nil_var
            if_var.nil_if_read = true
          else
            if_var.bind_to conditional_no_return(node.else, @program.nil_var)
          end
        elsif else_var
          if else_unreachable
            if_var.bind_to conditional_no_return(node.else, else_var)
          else
            if_var.bind_to else_var
          end

          if cond_var
            if_var.bind_to cond_var
          elsif !then_unreachable
            if_var.bind_to program.nil_var
            if_var.nil_if_read = true
          else
            if_var.bind_to conditional_no_return(node.then, @program.nil_var)
          end
        end

        @vars[name] = if_var
      end
    end

    def conditional_no_return(node, var)
      node.filtered_by NoReturnFilter.new(var)
    end

    def visit(node : While)
      old_while_vars = @while_vars

      before_cond_vars_copy = @vars.dup

      @vars.each do |name, var|
        before_var = MetaVar.new(name)
        before_var.bind_to(var)
        before_var.nil_if_read = var.nil_if_read?
        @vars[name] = before_var
      end

      before_cond_vars = @vars.dup

      request_type_filters do
        node.cond.accept self
      end

      cond_type_filters = @type_filters

      after_cond_vars = @vars.dup
      @while_vars = after_cond_vars

      filter_vars cond_type_filters

      @type_filters = nil
      @block, old_block = nil, @block

      @while_stack.push node
      node.body.accept self

      endless_while = node.cond.true_literal?
      merge_while_vars node.cond, endless_while, before_cond_vars_copy, before_cond_vars, after_cond_vars, @vars, node.break_vars

      @while_stack.pop
      @block = old_block
      @while_vars = old_while_vars

      unless node.has_breaks?
        if endless_while
          node.type = program.no_return
          return
        end
      end

      node.type = @program.nil

      false
    end

    # Here we assign the types of variables after a while.
    def merge_while_vars(cond, endless, before_cond_vars_copy, before_cond_vars, after_cond_vars, while_vars, all_break_vars)
      after_while_vars = MetaVars.new

      cond_var = get_while_cond_assign_target(cond)

      while_vars.each do |name, while_var|
        before_cond_var = before_cond_vars[name]?
        after_cond_var = after_cond_vars[name]?

        # If a variable was assigned in the condition, it has that type.
        if cond_var && (cond_var.name == name) && after_cond_var && !after_cond_var.same?(before_cond_var)
          after_while_var = MetaVar.new(name)
          after_while_var.bind_to(after_cond_var)
          after_while_var.nil_if_read = after_cond_var.nil_if_read?
          after_while_vars[name] = after_while_var

          # If there was a previous variable, we use that type merged
          # with the last type inside the while.
        elsif before_cond_var
          after_while_var = MetaVar.new(name)

          # If the loop is endless
          if endless
            after_while_var.bind_to(while_var)
            after_while_var.nil_if_read = while_var.nil_if_read?
          else
            # We need to bind to the variable *before* the condition, even
            # after before the variables that are used in the condition
            # `before_cond_vars` are modified in the while body
            after_while_var.bind_to(before_cond_vars_copy[name])
            after_while_var.bind_to(while_var)
            after_while_var.nil_if_read = before_cond_var.nil_if_read? || while_var.nil_if_read?
          end
          after_while_vars[name] = after_while_var

          # We must also bind the variable before the condition, because
          # its type now must also include the type at the exit of the while
          before_cond_var.bind_to(while_var)

          # Otherwise, it's a new variable inside the while: used
          # outside it must be nilable, unless the loop is endless.
        else
          after_while_var = MetaVar.new(name)
          after_while_var.bind_to(while_var)
          nilable = false
          if endless
            # In an endless loop if there's a break before a variable is declared,
            # that variable becomes nilable.
            unless all_break_vars.try &.all? &.has_key?(name)
              nilable = true
            end
          else
            nilable = true
          end
          if nilable
            after_while_var.bind_to(@program.nil_var)
            after_while_var.nil_if_read = true
          end
          after_while_vars[name] = after_while_var
        end
      end

      @vars = after_while_vars

      # We also need to merge types from breaks inside while.
      if all_break_vars
        all_break_vars.each do |break_vars|
          break_vars.each do |name, break_var|
            var = @vars[name]?
            unless var
              # Fix for issue #2441:
              # it might be that a break variable is not present
              # in the current vars after a while
              var = new_meta_var(name)
              var.bind_to(program.nil_var)
              @meta_vars[name].bind_to(program.nil_var)
              @vars[name] = var
            end
            var.bind_to(break_var)
          end
        end
      end
    end

    def get_while_cond_assign_target(node)
      case node
      when Assign
        target = node.target
        if target.is_a?(Var)
          return target
        end
      when And
        return get_while_cond_assign_target(node.left)
      when If
        if node.and?
          return get_while_cond_assign_target(node.cond)
        end
      when Call
        return get_while_cond_assign_target(node.obj)
      end

      nil
    end

    # If we have:
    #
    #   if a
    #     ...
    #   end
    #
    # then inside the if 'a' must not be nil.
    #
    # This is what we do here: we create a meta-variable for
    # it and filter it accordingly. This also applied to
    # .is_a? and .responds_to?.
    #
    # This also applies to 'while' conditions and also
    # to the else part of an if, but with filters inverted.
    def filter_vars(filters)
      filter_vars(filters) { |filter| filter }
    end

    def filter_vars(filters)
      filters.try &.each do |name, filter|
        existing_var = @vars[name]
        filtered_var = MetaVar.new(name)
        filtered_var.bind_to(existing_var.filtered_by(yield filter))
        @vars[name] = filtered_var
      end
    end

    def end_visit(node : Break)
      if block = @block
        node.target = block.call.not_nil!

        block.break.bind_to(node.exp || program.nil_var)

        bind_vars @vars, block.after_vars, block.args
      elsif target_while = @while_stack.last?
        node.target = target_while
        target_while.has_breaks = true

        break_vars = (target_while.break_vars ||= [] of MetaVars)
        break_vars.push @vars.dup
      else
        if @typed_def.try &.captured_block?
          node.raise "can't break from captured block"
        end

        node.raise "Invalid break"
      end

      @unreachable = true
    end

    def end_visit(node : Next)
      if block = @block
        node.target = block

        block.bind_to(node.exp || program.nil_var)

        bind_vars @vars, block.vars
        bind_vars @vars, block.after_vars, block.args
      elsif target_while = @while_stack.last?
        node.target = target_while

        bind_vars @vars, @while_vars
      else
        typed_def = @typed_def
        if typed_def && typed_def.captured_block?
          node.target = typed_def
          typed_def.bind_to(node.exp || program.nil_var)
        else
          node.raise "Invalid next"
        end
      end

      @unreachable = true
    end

    def visit(node : Primitive)
      case node.name
      when "binary"
        visit_binary node
      when "cast"
        visit_cast node
      when "allocate"
        visit_allocate node
      when "pointer_malloc"
        visit_pointer_malloc node
      when "pointer_set"
        visit_pointer_set node
      when "pointer_get"
        visit_pointer_get node
      when "pointer_address"
        node.type = @program.uint64
      when "pointer_new"
        visit_pointer_new node
      when "pointer_realloc"
        node.type = scope
      when "pointer_add"
        node.type = scope
      when "argc"
        # Already typed
      when "argv"
        # Already typed
      when "struct_new"
        node.type = scope.instance_type
      when "struct_set"
        visit_struct_or_union_set node
      when "struct_get"
        visit_struct_get node
      when "union_new"
        node.type = scope.instance_type
      when "union_set"
        visit_struct_or_union_set node
      when "union_get"
        visit_union_get node
      when "external_var_set"
        # Nothing to do
      when "external_var_get"
        # Nothing to do
      when "object_id"
        node.type = program.uint64
      when "object_crystal_type_id"
        node.type = program.int32
      when "symbol_to_s"
        node.type = program.string
      when "class"
        node.type = scope.metaclass
      when "proc_call"
        node.type = scope.as(ProcInstanceType).return_type
      when "pointer_diff"
        node.type = program.int64
      when "class_name"
        node.type = program.string
      when "enum_value"
        # Nothing to do
      when "enum_new"
        # Nothing to do
      else
        node.raise "Bug: unhandled primitive in MainVisitor: #{node.name}"
      end
    end

    def visit_binary(node)
      case typed_def.name
      when "+", "-", "*", "/", "unsafe_div"
        t1 = scope.remove_typedef
        t2 = typed_def.args[0].type
        node.type = t1.integer? && t2.float? ? t2 : scope
      when "==", "<", "<=", ">", ">=", "!="
        node.type = @program.bool
      when "%", "unsafe_shl", "unsafe_shr", "|", "&", "^", "unsafe_mod"
        node.type = scope
      else
        raise "Bug: unknown binary operator #{typed_def.name}"
      end
    end

    def visit_cast(node)
      node.type =
        case typed_def.name
        when "to_i", "to_i32", "ord" then program.int32
        when "to_i8"                 then program.int8
        when "to_i16"                then program.int16
        when "to_i32"                then program.int32
        when "to_i64"                then program.int64
        when "to_u", "to_u32"        then program.uint32
        when "to_u8"                 then program.uint8
        when "to_u16"                then program.uint16
        when "to_u32"                then program.uint32
        when "to_u64"                then program.uint64
        when "to_f", "to_f64"        then program.float64
        when "to_f32"                then program.float32
        when "unsafe_chr"            then program.char
        else
          raise "Bug: unknown cast operator #{typed_def.name}"
        end
    end

    def visit_allocate(node)
      instance_type = scope.instance_type

      case instance_type
      when GenericClassType
        node.raise "can't create instance of generic class #{instance_type} without specifying its type vars"
      when UnionType
        node.raise "can't create instance of a union type"
      when PointerInstanceType
        node.raise "can't create instance of a pointer type"
      end

      if !instance_type.virtual? && instance_type.abstract?
        node.raise "can't instantiate abstract #{instance_type.type_desc} #{instance_type}"
      end

      node.type = instance_type
    end

    def visit_pointer_malloc(node)
      if scope.instance_type.is_a?(GenericClassType)
        node.raise "can't malloc pointer without type, use Pointer(Type).malloc(size)"
      end

      node.type = scope.instance_type
    end

    def visit_pointer_set(node)
      scope = scope().remove_typedef.as(PointerInstanceType)

      # We don't want to change the value of Pointer(Void) to include Nil (Nil passes as Void)
      if scope.element_type.void?
        node.type = @program.nil
        return
      end

      value = @vars["value"]

      scope.var.bind_to value
      node.bind_to value
    end

    def visit_pointer_get(node)
      scope = scope().remove_typedef.as(PointerInstanceType)

      node.bind_to scope.var
    end

    def visit_pointer_new(node)
      if scope.instance_type.is_a?(GenericClassType)
        node.raise "can't create pointer without type, use Pointer(Type).new(address)"
      end

      node.type = scope.instance_type
    end

    def visit_struct_or_union_set(node)
      scope = @scope.as(CStructOrUnionType)

      field_name = call.not_nil!.name.chop
      expected_type = scope.instance_vars['@' + field_name].type
      value = @vars["value"]
      actual_type = value.type

      node.type = actual_type

      actual_type = actual_type.remove_alias
      unaliased_type = expected_type.remove_alias

      return if actual_type.compatible_with?(unaliased_type)
      return if actual_type.implicitly_converted_in_c_to?(unaliased_type)

      case unaliased_type
      when IntegerType
        if convert_call = convert_struct_or_union_numeric_argument(node, unaliased_type, expected_type, actual_type)
          node.extra = convert_call
          return
        end
      when FloatType
        if convert_call = convert_struct_or_union_numeric_argument(node, unaliased_type, expected_type, actual_type)
          node.extra = convert_call
          return
        end
      end

      unsafe_call = Conversions.to_unsafe(node, Var.new("value"), self, actual_type, expected_type)
      if unsafe_call
        node.extra = unsafe_call
        return
      end

      node.raise "field '#{field_name}' of #{scope.type_desc} #{scope} has type #{expected_type}, not #{actual_type}"
    end

    def convert_struct_or_union_numeric_argument(node, unaliased_type, expected_type, actual_type)
      Conversions.numeric_argument(node, Var.new("value"), self, unaliased_type, expected_type, actual_type)
    end

    def visit_struct_get(node)
      scope = @scope.as(CStructType)
      node.bind_to scope.instance_vars['@' + untyped_def.name]
    end

    def visit_union_get(node)
      scope = @scope.as(CUnionType)
      node.bind_to scope.instance_vars['@' + untyped_def.name]
    end

    def visit(node : PointerOf)
      var = case node_exp = node.exp
            when Var
              meta_var = @meta_vars[node_exp.name]
              meta_var.assigned_to = true
              meta_var
            when InstanceVar
              lookup_instance_var node_exp
            when ClassVar
              visit_class_var node_exp
            when Global
              visit_global node_exp
            when Path
              node_exp.accept self
              if const = node_exp.target_const
                const.value
              else
                node_exp.raise "can't take address of #{node_exp}"
              end
            when ReadInstanceVar
              visit_read_instance_var(node_exp)
              node_exp
            else
              node_exp.raise "can't take address of #{node_exp}"
            end
      node.bind_to var
    end

    def visit(node : TypeOf)
      # A typeof shouldn't change the type of variables:
      # so we keep the ones before it and restore them at the end
      old_vars = @vars.dup

      node.in_type_args = @in_type_args > 0

      old_in_type_args = @in_type_args
      @in_type_args = 0

      @typeof_nest += 1
      node.expressions.each &.accept self
      @typeof_nest -= 1

      @in_type_args = old_in_type_args

      node.bind_to node.expressions

      @vars = old_vars

      false
    end

    def visit(node : SizeOf)
      @in_type_args += 1
      node.exp.accept self
      @in_type_args -= 1

      # Try to resolve the sizeof right now to a number literal
      # (useful for sizeof inside as a generic type argument, but also
      # to make it easier for LLVM to optimize things)
      if (type = node.exp.type?) && !node.exp.is_a?(TypeOf)
        expanded = NumberLiteral.new(@program.size_of(type))
        expanded.type = @program.int32
        node.expanded = expanded
      end
      node.type = @program.int32
      false
    end

    def visit(node : InstanceSizeOf)
      @in_type_args += 1
      node.exp.accept self
      @in_type_args -= 1

      # Try to resolve the instance_sizeof right now to a number literal
      # (useful for sizeof inside as a generic type argument, but also
      # to make it easier for LLVM to optimize things)
      if (type = node.exp.type?) && type.instance_type.class? && !node.exp.is_a?(TypeOf)
        expanded = NumberLiteral.new(@program.instance_size_of(type))
        expanded.type = @program.int32
        node.expanded = expanded
      end
      node.type = @program.int32
      false
    end

    def visit(node : Rescue)
      if node_types = node.types
        types = node_types.map do |type|
          type.accept self
          instance_type = type.type.instance_type
          unless instance_type.subclass_of?(@program.exception)
            type.raise "#{type} is not a subclass of Exception"
          end
          instance_type
        end
      end

      if node_name = node.name
        var = @vars[node_name] = new_meta_var(node_name)
        meta_var = (@meta_vars[node_name] ||= new_meta_var(node_name))
        meta_var.bind_to(var)
        meta_var.assigned_to = true

        if types
          unified_type = @program.type_merge(types).not_nil!
          unified_type = unified_type.virtual_type unless unified_type.is_a?(VirtualType)
        else
          unified_type = @program.exception.virtual_type
        end
        var.type = unified_type
        var.freeze_type = unified_type

        node.set_type(var.type)
      end

      node.body.accept self

      false
    end

    def visit(node : ExceptionHandler)
      old_exception_handler_vars = @exception_handler_vars

      # Save old vars to know if new variables are declared inside begin/rescue/else
      before_body_vars = @vars.dup

      # Any variable assigned in the body (begin) will have, inside rescue
      # blocks, all types that were assigned to them, because we can't know at which
      # point an exception is raised.
      exception_handler_vars = @exception_handler_vars = @vars.dup

      node.body.accept self

      # We need the variables after the begin block to use in the else,
      # but we don't dup them if we don't need them
      if node.else
        after_exception_handler_vars = @vars.dup
      end

      @exception_handler_vars = nil

      if node.rescues || node.else
        # Any variable introduced in the begin block is possibly nil
        # in the rescue blocks because we can't know if an exception
        # was raised before assigning any of the vars.
        exception_handler_vars.each do |name, var|
          unless before_body_vars[name]?
            var.nil_if_read = true
          end
        end

        # Now, using these vars, visit all rescue blocks and keep
        # the results in this variable.
        all_rescue_vars = [] of MetaVars

        node.rescues.try &.each do |a_rescue|
          @vars = exception_handler_vars.dup
          @unreachable = false
          a_rescue.accept self
          all_rescue_vars << @vars unless @unreachable
        end

        # In the else block the types are the same as in the begin block,
        # because we assume no exception was raised.
        node.else.try do |a_else|
          @vars = after_exception_handler_vars.not_nil!.dup
          @unreachable = false
          a_else.accept self
          all_rescue_vars << @vars unless @unreachable
        end

        # If all rescue/else blocks are unreachable, then afterwards
        # the flow continues as if there were no rescue/else blocks.
        if all_rescue_vars.empty?
          all_rescue_vars = nil
        else
          # Otherwise, merge all types that resulted from all rescue/else blocks
          merge_rescue_vars exception_handler_vars, all_rescue_vars

          # And then accept the ensure part
          node.ensure.try &.accept self
        end
      end

      # If there were no rescue/else blocks or all of them were unreachable
      unless all_rescue_vars
        if node_ensure = node.ensure
          after_handler_vars = @vars
          @vars = exception_handler_vars

          # Variables in the ensure block might be nil because we don't know
          # if an exception was thrown before any assignment.
          @vars.each do |name, var|
            unless before_body_vars[name]?
              var.nil_if_read = true
            end
          end

          node_ensure.accept self

          @vars = after_handler_vars
        else
          @vars = exception_handler_vars
        end

        # However, those previous variables can't be nil afterwards:
        # if an exception was raised then we won't running the code
        # after the ensure clause, so variables don't matter. But if
        # an exception was not raised then all variables were declared
        # successfully.
        @vars.each do |name, var|
          unless before_body_vars[name]?
            var.nil_if_read = false
          end
        end
      end

      if node_ensure = node.ensure
        node_ensure.add_observer(node)
      end

      if node_else = node.else
        node.bind_to node_else
      else
        node.bind_to node.body
      end

      if node_rescues = node.rescues
        node_rescues.each do |a_rescue|
          node.bind_to a_rescue.body
        end
      end

      old_exception_handler_vars = @exception_handler_vars

      false
    end

    def merge_rescue_vars(body_vars, all_rescue_vars)
      after_vars = MetaVars.new

      all_rescue_vars.each do |rescue_vars|
        rescue_vars.each do |name, var|
          after_var = (after_vars[name] ||= new_meta_var(name))
          if var.nil_if_read? || !body_vars[name]?
            after_var.bind_to(program.nil_var)
            after_var.nil_if_read = true
          end
          after_var.bind_to(var)
        end
      end

      body_vars.each do |name, var|
        after_var = (after_vars[name] ||= new_meta_var(name))
        after_var.bind_to(var)
      end

      @vars = after_vars
    end

    def end_visit(node : TupleLiteral)
      node.elements.each &.add_observer(node)
      node.program = @program
      node.update
      false
    end

    def end_visit(node : NamedTupleLiteral)
      node.entries.each &.value.add_observer(node)
      node.program = @program
      node.update
      false
    end

    def visit(node : TupleIndexer)
      scope = @scope
      if scope.is_a?(TupleInstanceType)
        node.type = scope.tuple_types[node.index].as(Type)
      elsif scope.is_a?(NamedTupleInstanceType)
        node.type = scope.entries[node.index].type
      elsif scope
        node.type = (scope.instance_type.as(TupleInstanceType).tuple_types[node.index].as(Type)).metaclass
      end
      false
    end

    def visit(node : Asm)
      if output = node.output
        ptrof = PointerOf.new(output.exp).at(output.exp)
        ptrof.accept self
        node.ptrof = ptrof
      end

      if inputs = node.inputs
        inputs.each &.exp.accept self
      end

      node.type = @program.void
      false
    end

    def check_call_convention_attributes(node)
      attributes = @attributes
      return unless attributes

      call_convention = nil

      attributes.reject! do |attr|
        next false unless attr.name == "CallConvention"

        if call_convention
          attr.raise "call convention already specified"
        end

        if attr.args.size != 1
          attr.wrong_number_of_arguments "attribute CallConvention", attr.args.size, 1
        end

        call_convention_node = attr.args.first
        unless call_convention_node.is_a?(StringLiteral)
          call_convention_node.raise "argument to CallConvention must be a string"
        end

        value = call_convention_node.value
        call_convention = LLVM::CallConvention.parse?(value)
        unless call_convention
          call_convention_node.raise "invalid call convention. Valid values are #{LLVM::CallConvention.values.join ", "}"
        end

        true
      end

      call_convention
    end

    # # Literals

    def visit(node : Nop)
      node.type = @program.nil
    end

    def visit(node : NilLiteral)
      node.type = @program.nil
    end

    def visit(node : BoolLiteral)
      node.type = program.bool
    end

    def visit(node : NumberLiteral)
      node.type = case node.kind
                  when :i8  then program.int8
                  when :i16 then program.int16
                  when :i32 then program.int32
                  when :i64 then program.int64
                  when :u8  then program.uint8
                  when :u16 then program.uint16
                  when :u32 then program.uint32
                  when :u64 then program.uint64
                  when :f32 then program.float32
                  when :f64 then program.float64
                  else           raise "Invalid node kind: #{node.kind}"
                  end
    end

    def visit(node : CharLiteral)
      node.type = program.char
    end

    def visit(node : SymbolLiteral)
      node.type = program.symbol
      program.symbols.add node.value
    end

    def visit(node : StringLiteral)
      node.type = program.string
    end

    def visit(node : RegexLiteral)
      expand(node)
    end

    def visit(node : ArrayLiteral)
      if name = node.name
        name.accept self
        type = name.type.instance_type

        case type
        when GenericClassType
          type_name = type.name.split "::"

          path = Path.global(type_name).at(node.location)
          type_of = TypeOf.new(node.elements).at(node.location)
          generic = Generic.new(path, type_of).at(node.location)

          node.name = generic
        when GenericClassInstanceType
          # Nothing
        else
          type_name = type.to_s.split "::"
          path = Path.global(type_name).at(node.location)
          node.name = path
        end

        expand_named(node)
      else
        expand(node)
      end
    end

    def visit(node : HashLiteral)
      if name = node.name
        name.accept self
        type = name.type.instance_type

        case type
        when GenericClassType
          type_name = type.name.split "::"

          path = Path.global(type_name).at(node.location)
          type_of_keys = TypeOf.new(node.entries.map { |x| x.key.as(ASTNode) }).at(node.location)
          type_of_values = TypeOf.new(node.entries.map { |x| x.value.as(ASTNode) }).at(node.location)
          generic = Generic.new(path, [type_of_keys, type_of_values] of ASTNode).at(node.location)

          node.name = generic
        when GenericClassInstanceType
          # Nothing
        else
          type_name = type.to_s.split "::"

          path = Path.global(type_name).at(node.location)

          node.name = path
        end

        expand_named(node)
      else
        expand(node)
      end
    end

    def visit(node : And)
      expand(node)
    end

    def visit(node : Or)
      expand(node)
    end

    def visit(node : RangeLiteral)
      expand(node)
    end

    def visit(node : StringInterpolation)
      expand(node)

      # This allows some methods to be resolved even if the interpolated expressions doesn't
      # end up with a type because of recursive methods. We should really do something more
      # clever and robust here for the general case.
      node.type = program.string

      false
    end

    def visit(node : Case)
      expand(node)
      false
    end

    def visit(node : MultiAssign)
      expand(node)
      false
    end

    def expand(node)
      expand(node) { @program.literal_expander.expand node }
    end

    def expand_named(node)
      expand(node) { @program.literal_expander.expand_named node }
    end

    def expand(node)
      expanded = yield
      expanded.accept self
      node.expanded = expanded
      node.bind_to expanded
      false
    end

    def visit(node : Not)
      node.exp.accept self
      node.exp.add_observer node
      node.update

      if needs_type_filters? && (type_filters = @type_filters)
        @type_filters = type_filters.not
      else
        @type_filters = nil
      end

      false
    end

    def visit(node : VisibilityModifier)
      exp = node.exp
      exp.accept self

      # Only check for calls that didn't resolve to a macro:
      # all other cases are already covered in TopLevelVisitor
      if exp.is_a?(Call) && !exp.expanded
        node.raise "can't apply visibility modifier"
      end

      false
    end

    # # Helpers

    def check_closured(var)
      return if @typeof_nest > 0

      if var.name == "self"
        check_self_closured
        return
      end

      context = current_context
      var_context = var.context
      if !var_context.same?(context)
        # If the contexts are not the same, it might be that we are in a block
        # inside a method, or a block inside another block. We don't want
        # those cases to closure a variable. So if any context is a block
        # we go to the block's context (a def or a proc literal) and compare
        # if those are the same to determine whether the variable is closured.
        context = context.context if context.is_a?(Block)
        var_context = var_context.context if var_context.is_a?(Block)

        closured = !context.same?(var_context)
        if closured
          var.closured = true

          # Go up and mark proc literal defs as closured until we get
          # to the context where the variable is defined
          visitor = self
          while visitor
            visitor_context = visitor.closure_context
            break if visitor_context == var_context

            visitor_context.closure = true if visitor_context.is_a?(Def)
            visitor = visitor.parent
          end
        end
      end
    end

    def check_self_closured
      scope = @scope
      return unless scope

      return if scope.metaclass? && !scope.virtual_metaclass?

      context = @fun_literal_context
      return unless context.is_a?(Def)

      context.self_closured = true

      # Go up and mark proc literal defs as closured until the top
      # (which should be when we leave the top Def)
      visitor = self
      while visitor
        visitor_context = visitor.closure_context
        visitor_context.closure = true if visitor_context.is_a?(Def)
        visitor = visitor.parent
      end
    end

    def current_context
      @block_context || current_non_block_context
    end

    def current_non_block_context
      @typed_def || @file_module || @program
    end

    def closure_context
      context = current_context
      context = context.context if context.is_a?(Block)
      context
    end

    def lookup_var_or_instance_var(var : Var)
      @vars[var.name]
    end

    def lookup_var_or_instance_var(var : InstanceVar)
      scope = @scope.as(InstanceVarContainer)
      scope.lookup_instance_var(var.name)
    end

    def lookup_var_or_instance_var(var)
      raise "Bug: trying to lookup var or instance var but got #{var}"
    end

    def bind_meta_var(var : Var)
      @meta_vars[var.name].bind_to(var)
    end

    def bind_meta_var(var : InstanceVar)
      # Nothing to do
    end

    def bind_meta_var(var)
      raise "Bug: trying to bind var or instance var but got #{var}"
    end

    def bind_initialize_instance_vars(owner)
      names_to_remove = [] of String

      @vars.each do |name, var|
        if name.starts_with? '@'
          if var.nil_if_read?
            ivar = owner.lookup_instance_var(name)
            ivar.bind_to program.nil_var
          end

          names_to_remove << name
        end
      end

      names_to_remove.each do |name|
        @meta_vars.delete name
        @vars.delete name
      end
    end

    def needs_type_filters?
      @needs_type_filters > 0
    end

    def request_type_filters
      @type_filters = nil
      @needs_type_filters += 1
      begin
        yield
      ensure
        @needs_type_filters -= 1
      end
    end

    def ignoring_type_filters
      needs_type_filters, @needs_type_filters = @needs_type_filters, 0
      begin
        yield
      ensure
        @needs_type_filters = needs_type_filters
      end
    end

    def lookup_similar_var_name(name)
      Levenshtein.find(name) do |finder|
        @vars.each_key do |var_name|
          finder.test(var_name)
        end
      end
    end

    def define_special_var(name, value)
      meta_var = (@meta_vars[name] ||= new_meta_var(name))
      meta_var.bind_to value
      meta_var.bind_to program.nil_var unless meta_var.dependencies.any? &.same?(program.nil_var)
      meta_var.assigned_to = true
      check_closured meta_var

      @vars[name] = meta_var
      meta_var
    end

    def new_meta_var(name, context = current_context)
      meta_var = MetaVar.new(name)
      meta_var.context = context
      meta_var
    end

    def block=(@block)
      @block_context = @block
    end

    def inside_block?
      @untyped_def || @block_context
    end

    def visit(node : When | Unless | Until | MacroLiteral)
      raise "Bug: #{node.class_desc} node '#{node}' (#{node.location}) should have been eliminated in normalize"
    end
  end
end
