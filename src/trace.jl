# Naming:
# v_xxx - Variable xxx
# sv_xxx - SSAValue xxx or Argument xxx
# pc - SSA ID (abbreviation from "program counter")
# bi - block ID


###############################################################################
#                                  Frame                                      #
###############################################################################

"""
    block_expressions(ir::IRCode)

For each block, compute a vector of its expressions along with their SSA IDs.
Returns Vector{block_info}, where block_info is Vector{ssa_id => expr}
"""
function block_expressions(ir::IRCode)
    # new statements
    new_exs = ir.new_nodes.stmts.inst
    # where to insert them
    new_positions = [(info.attach_after ? info.pos + 1 : info.pos)
                    for info in ir.new_nodes.info]
    # their indices (program counters)
    new_pcs = [idx + length(ir.stmts) for idx=1:length(new_exs)]
    new_node_map = Dict{Int, Vector{Any}}()
    for (pos, pc, ex) in zip(new_positions, new_pcs, new_exs)
        if !haskey(new_node_map, pos)
            new_node_map[pos] = []
        end
        push!(new_node_map[pos], (pc, ex))
    end
    block_exprs = Vector{Vector{Tuple}}(undef, 0)
    for bi in eachindex(ir.cfg.blocks)
        pc_exprs = Tuple[]
        for pos in ir.cfg.blocks[bi].stmts
            if haskey(new_node_map, pos)
                for pc_ex in new_node_map[pos]
                    push!(pc_exprs, pc_ex)
                end
            end
            push!(pc_exprs, (pos, ir.stmts[pos][:inst]))
        end
        push!(block_exprs, pc_exprs)
    end
    return block_exprs
end


mutable struct Frame
    # typically values are Variables, but can also be constant values
    ir2tape::Dict{Union{SSAValue, Argument}, Any}
    # block_exprs[bi] = [(pc => expr), ...]
    block_exprs::Vector{Vector{Tuple}}
    # map from pc to corresponding block ID
    pc_blocks::Dict{Int, Int}
    # debug info
    ir::IRCode
    v_fargs
end


function Frame(tape::Tape, ir::IRCode, v_fargs...)
    ir2tape = Dict{Union{SSAValue, Argument}, Any}()
    for (i, v) in enumerate(v_fargs)
        if v isa V
            ir2tape[Argument(i)] = v
        else
            # c = push!(tape, Constant(promote_const_value(v)))
            # ir2tape[Argument(i)] = c
            ir2tape[Argument(i)] = v  # experimental
            # TODO: unify code in 2 branches if it works this way
        end
    end
    block_exprs = block_expressions(ir)
    pc_blocks = Dict([pc => bi for bi in eachindex(block_exprs) for (pc, _) in block_exprs[bi]])
    return Frame(ir2tape, block_exprs, pc_blocks, ir, v_fargs)
end


getid(x::SSAValue) = x.id
getid(x::Argument) = x.n


function Base.show(io::IO, frame::Frame)
    s = "Frame(\n"
    for (sv, v) in sort(frame.ir2tape, by=getid)
        s *= "  $sv => $v\n"
    end
    s *= ")"
    print(io, s)
end


function resolve_tape_vars(frame::Frame, sv_fargs...)
    v_fargs = []
    for sv in sv_fargs
        if sv isa Argument || sv isa SSAValue
            push!(v_fargs, frame.ir2tape[sv])
        else
            push!(v_fargs, promote_const_value(sv))
        end
    end
    return v_fargs
end


###############################################################################
#                           Context & Primitives                              #
###############################################################################

"""
Dict-like tracing context that treats as primitives all functions from the
standard Julia modules (e.g. Base, Core, Statistics, etc.)
"""
struct BaseCtx
    primitives::Set
    data::Dict
end

BaseCtx() = BaseCtx(Set(), Dict())
BaseCtx(primitives) = BaseCtx(Set(primitives), Dict())

function Base.show(io::IO, ctx::BaseCtx)
    n_primitives = length(ctx.primitives)
    n_entries = length(ctx.data)
    print(io, "BaseCtx($n_primitives primitives, $n_entries entries)")
end

Base.getindex(ctx::BaseCtx, key) = getindex(ctx.data, key)
Base.setindex!(ctx::BaseCtx, val, key) = setindex!(ctx.data, val, key)


"""
    isprimitive(ctx::BaseCtx, f, args...)

The default implementation of `isprimitive` used in [`trace()`](@ref).
Returns `true` if the method with the provided signature is defined
in one of the Julia's built-in modules, e.g. `Base`, `Core`, `Broadcast`, etc.
"""
function isprimitive(ctx::BaseCtx, f, args...)
    if isempty(ctx.primitives)
        f in (__new__, Colon(), Base.Generator) && return true
        f isa NamedTuple && return true
        modl = module_of(f)
        modl in (Base, Core, Core.Intrinsics, Broadcast, Statistics, LinearAlgebra) && return true
        return false
    else
        return f in ctx.primitives
    end
end


"""
    isprimitive(ctx::Any, f, args...)

Fallback implementation of `isprimitive()`, behaves the same way
as `isprimitive(BaseCtx(), f, args...)`.
"""
isprimitive(ctx::Any, f, args...) = isprimitive(BaseCtx(), f, args...)


"""
    record_primitive!(tape::Tape{C}, v_fargs...) where C

Record a primitive function call to the tape.

By default, this function simply pushes the function call to the tape,
but it can also be overwritten to do more complex logic. For example,
instead of recording the function call, a user can push one or more
other calls, essentially implementing `replace!()` right during the
tracing and without calling the function twice.

Examples:
=========

The following code shows how to replace f(args...) with ChainRules.rrule(f, args...)
duing the tracing:

    function record_primitive!(tape::Tape{RRuleContext}, v_fargs)
        v_rr = push!(tape, mkcall(rrule, v_fargs...))
        v_val = push!(tape, mkcall(getfield, v_rr, 1))
        v_pb = push!(tape, mkcall(getfield, v_rr, 1))
        tape.c.pullbacks[v_val] = v_pb
        return v_val   # the function should return Variable with the result
    end


See also: [`isprimitive()`](@ref)
"""
record_primitive!(tape::Tape, v_fargs...) = push!(tape, mkcall(v_fargs...))


###############################################################################
#                                 Tracing                                     #
###############################################################################


mutable struct Tracer{C}
    tape::Tape{C}
    stack::Vector{Frame}
end

Tracer(tape::Tape{C}) where C = Tracer{C}(tape, [])


function get_ir(f, args...)
    types = map(Core.Typeof, (f, args...))
    irs = code_ircode_by_signature(no_pass, Tuple{types...})
    @assert !isempty(irs) "No IR found for types $types"
    @assert length(irs) == 1 "More than one IR found for types $types"
    return irs[1][1]
end



function rewrite_special_cases(st::Expr)
    ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
    if Meta.isexpr(ex, :new)
        ex = Expr(:call, __new__, ex.args...)
    end
    return Meta.isexpr(st, :(=)) ? Expr(:(=), st.args[1], ex) : ex
end
rewrite_special_cases(st) = st


function get_static_params(t::Tracer, v_fargs)
    fvals = [v isa V ? t.tape[v].val : v for v in v_fargs]
    fn, vals... = fvals
    mi = Base.method_instances(fn, map(Core.Typeof, vals))[1]
    return mi.sparam_vals
end


function group_varargs(t::Tracer, v_fargs)
    fargs = map_vars(v -> t.tape[v].val, v_fargs)
    fargtypes = (fargs[1], map(Core.Typeof, fargs[2:end]))
    meth = which(fargtypes...)
    v_f, v_args... = v_fargs
    if meth.isva
        va = push!(t.tape, mkcall(tuple, v_args[meth.nargs - 1:end]...))
        v_args = (v_args[1:meth.nargs - 2]..., va)
    end
    return (v_f, v_args...)
end


"""
    trace_call!(t::Tracer{C}, v_f, v_args...) where C

Customizable handler that controls what to do with a function call.
The default implementation checks if the call is a primitive and either
records it to the tape or recurses into it.
"""
function trace_call!(t::Tracer{C}, vs...) where C
    fargs = [v isa V ? t.tape[v].val : v for v in vs]
    return if isprimitive(t.tape.c, fargs...)
        record_primitive!(t.tape, vs...)
    else
        vs = group_varargs(t, vs)
        trace!(t, get_ir(fargs...), vs...)
    end
end


function record_or_recurse(t, vs...)
    @warn "record_or_recurse(t, vs...) is deprecated, use trace_call!(t, vs...) instead"
    trace_call!(t, vs...)
end


is_control_flow(ex) = ex isa GotoNode || ex isa GotoIfNot || ex isa ReturnNode


function trace_block!(t::Tracer, ir::IRCode, bi::Integer, prev_bi::Integer, sparams)
    frame = t.stack[end]
    for (pc, ex) in frame.block_exprs[bi]
        ex = rewrite_special_cases(ex)
        if is_control_flow(ex)
            return ex   # exit on control flow statement
        elseif ex isa Core.PhiNode
            # map current pc to the currently active value of Phi node
            ir2tape = t.stack[end].ir2tape
            k = indexin(prev_bi, ex.edges)[]
            ir2tape[SSAValue(pc)] = ir2tape[ex.values[k]]
        elseif ex isa Core.PiNode
            val = t.tape[frame.ir2tape[ex.val]].val
            frame.ir2tape[SSAValue(pc)] = push!(t.tape, Constant(val))
        elseif Meta.isexpr(ex, :call)
            vs = resolve_tape_vars(frame, ex.args...)
            vs = [Meta.isexpr(x, :static_parameter) ? sparams[x.args[1]] : x for x in vs]
            v = trace_call!(t, vs...)
            frame.ir2tape[SSAValue(pc)] = v
        elseif ex isa SSAValue || ex isa Argument
            # assignment
            sv = SSAValue(pc)
            frame.ir2tape[sv] = frame.ir2tape[ex]
        elseif ex isa Expr && ex.head in [:code_coverage_effect]
            # ignored expressions, just skip it
        elseif ex isa Expr
            error("Unexpected expression: $ex\nFull IRCode:\n\n $ir")
        else
            # treat as constant
            v = push!(t.tape, Constant(promote_const_value(ex)))
            frame.ir2tape[SSAValue(pc)] = v
        end
    end
    return  # exit on implicit fallthrough
end


function trace!(t::Tracer, ir::IRCode, v_fargs...)
    frame = Frame(t.tape, ir, v_fargs...)
    push!(t.stack, frame)
    sparams = get_static_params(t, v_fargs)
    bi = 1
    prev_bi = 0
    cf = nothing
    while bi <= length(ir.cfg.blocks)
        cf = trace_block!(t, ir, bi, prev_bi, sparams)
        if isnothing(cf)
            # fallthrough to the next block
            prev_bi = bi
            bi += 1
        elseif cf isa Core.GotoIfNot
            # conditional jump
            cond_val = (cf.cond isa Argument || cf.cond isa SSAValue ?
                        t.tape[frame.ir2tape[cf.cond]].val :   # resolve tape var
                        cf.cond)                               # literal condition (e.g. while true)
            # if not cond, set i to destination, otherwise step forward
            prev_bi = bi
            bi = !cond_val ? cf.dest : bi + 1
        elseif cf isa Core.GotoNode
            # unconditional jump
            prev_bi = bi
            bi = cf.label
        elseif cf isa ReturnNode
            pc = cf.val
            if pc isa SSAValue || pc isa Argument
                val = frame.ir2tape[pc]
                v = val isa V ? val : push!(t.tape, Constant(promote_const_value(val)))
                pop!(t.stack)
                return v
            else
                v = push!(t.tape, Constant(promote_const_value(pc)))
                pop!(t.stack)
                return v
            end
        else
            error("Panic! Don't know how to handle control flow expression $cf")
        end
    end
    pop!(t.stack)
    # if no ReturnNode was encountered, use last op on the tape
    return V(t.tape[V(end)])
end


const LATEST_TRACER = Ref{Tracer}()



"""
    trace(f, args...; ctx=BaseCtx())

Trace function call, return the result and the corresponding Tape.
`trace` records to the tape primitive methods and recursively dives into
non-primitives.

Tracing can be customized using a context and the following methods:

* isprimitive(ctx, f, args...) - decides whethere `f(args...)` should be
  treated as a primitive.
* record_primitive!(tape::Tape{C}, v_f, v_args...) - records the primitive
  call defined by variables `f_v(v_args...)` to the tape.

The default context is `BaseCtx()`, which treats all functions from standard
Julia modules as primitives and simply pushes the call to the tape. See the
docstrings of these functions for further examples of customization.

Examples:
=========

    foo(x) = 2x
    bar(x) = foo(x) + 1

    val, tape = trace(bar, 2.0)
    # (5.0, Tape{Dict{Any, Any}}
    #   inp %1::typeof(bar)
    #   inp %2::Float64
    #   %3 = *(2, %2)::Float64
    #   %4 = +(%3, 1)::Float64
    # )

    val, tape = trace(bar, 2.0; ctx=BaseCtx([*, +, foo]))
    # (5.0, Tape{Dict{Any, Any}}
    #   inp %1::typeof(bar)
    #   inp %2::Float64
    #   %3 = foo(%2)::Float64
    #   %4 = +(%3, 1)::Float64
    # )

    struct MyCtx end

    isprimitive(ctx::MyCtx, f, args...) = isprimitive(BaseCtx(), f, args...) || f in [foo]
    val, tape = trace(bar, 2.0; ctx=MyCtx())
    # (5.0, Tape{Dict{Any, Any}}
    #   inp %1::typeof(bar)
    #   inp %2::Float64
    #   %3 = foo(%2)::Float64
    #   %4 = +(%3, 1)::Float64
    # )
"""
function trace(f, args...; ctx=BaseCtx(), fargtypes=nothing, deprecated_kws...)
    warn_deprecated_keywords(deprecated_kws)
    # if isnothing(fargtypes)
    fargtypes = (f, map(Core.Typeof, args))
    # end
    t = Tracer(Tape(ctx))
    meth = which(fargtypes...)
    xargs = meth.isva ? (args[1:meth.nargs - 2]..., args[meth.nargs - 1:end]) : args
    t.tape.meta[:isva] = meth.isva
    v_fargs = inputs!(t.tape, f, xargs...)
    ir = get_ir(f, args...)
    try
        rv = trace!(t, ir, v_fargs...)
        t.tape.result = rv
        return t.tape[t.tape.result].val, t.tape
    catch
        LATEST_TRACER[] = t
        rethrow()
    end
end


###############################################################################
#                           Post-tracing utils                                #
###############################################################################


get_latest_tracer() = LATEST_TRACER[]

function get_latest_tracer_state()
    t = get_latest_tracer()
    frame = t.stack[end]
    return t, frame.ci, frame.v_fargs
end

function print_stack_trace()
    t = get_latest_tracer()
    for (i, frame) in enumerate(reverse(t.stack))
        fn, args... = [v isa V ? t.tape[v].val : v for v in frame.v_fargs]
        meth = which(fn, map(Core.Typeof, args))
        println("[$i] $meth")
        # println("  @ $(meth.module) $(meth.file)")
    end
end