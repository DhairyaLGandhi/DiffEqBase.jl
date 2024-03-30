# Handled in Extensions
value(x) = x
isdistribution(u0) = false

_vec(v) = vec(v)
_vec(v::Number) = v
_vec(v::AbstractSciMLScalarOperator) = v
_vec(v::AbstractVector) = v

_reshape(v, siz) = reshape(v, siz)
_reshape(v::Number, siz) = v
_reshape(v::AbstractSciMLScalarOperator, siz) = v

macro tight_loop_macros(ex)
    :($(esc(ex)))
end

# TODO: would be good to have dtmin a function of dt
function prob2dtmin(prob; use_end_time = true)
    prob2dtmin(prob.tspan, oneunit(eltype(prob.tspan)), use_end_time)
end

# This functino requires `eps` to exist, which restricts below `<: Real`
# Example of a failure is Rational
function prob2dtmin(tspan, ::Union{AbstractFloat, ForwardDiff.Dual}, use_end_time)
    t1, t2 = tspan
    isfinite(t1) || throw(ArgumentError("t0 in the tspan `(t0, t1)` must be finite"))
    if use_end_time && isfinite(t2 - t1)
        return max(eps(t2), eps(t1))
    else
        return max(eps(typeof(t1)), eps(t1))
    end
end
prob2dtmin(tspan, ::Integer, ::Any) = 0
# Multiplication is for putting the right units on the constant!
prob2dtmin(tspan, onet, ::Any) = onet * 1 // Int64(2)^33 # roughly 10^10 but more likely to turn into a multiplication.

function timedepentdtmin(integrator::DEIntegrator)
    timedepentdtmin(integrator.t, integrator.opts.dtmin)
end
timedepentdtmin(t::AbstractFloat, dtmin) = abs(max(eps(t), dtmin))
timedepentdtmin(::Any, dtmin) = abs(dtmin)

maybe_with_logger(f, logger) = logger === nothing ? f() : Logging.with_logger(f, logger)

function default_logger(logger)
    Logging.min_enabled_level(logger) ≤ ProgressLogging.ProgressLevel && return nothing

    if Sys.iswindows() || (isdefined(Main, :IJulia) && Main.IJulia.inited)
        progresslogger = ConsoleProgressMonitor.ProgressLogger()
    else
        progresslogger = TerminalLoggers.TerminalLogger()
    end

    logger1 = LoggingExtras.EarlyFilteredLogger(progresslogger) do log
        log.level == ProgressLogging.ProgressLevel
    end
    logger2 = LoggingExtras.EarlyFilteredLogger(logger) do log
        log.level != ProgressLogging.ProgressLevel
    end

    LoggingExtras.TeeLogger(logger1, logger2)
end

# for the non-unitful case the correct type is just u
_rate_prototype(u, t::T, onet::T) where {T} = u

# Nonlinear Solve functionality
@inline __fast_scalar_indexing(args...) = all(ArrayInterface.fast_scalar_indexing, args)

@inline __maximum_abs(op::F, x, y) where {F} = __maximum(abs ∘ op, x, y)
## Nonallocating version of maximum(op.(x, y))
@inline function __maximum(op::F, x, y) where {F}
    if __fast_scalar_indexing(x, y)
        return maximum(@closure((xᵢyᵢ)->begin
                xᵢ, yᵢ = xᵢyᵢ
                return abs(op(xᵢ, yᵢ))
            end), zip(x, y))
    else
        return mapreduce(@closure((xᵢ, yᵢ)->@.(abs(op(xᵢ, yᵢ)))), max, x, y)
    end
end

function __nonlinearsolve_is_approx(x::Number, y::Number; atol = false,
        rtol = atol > 0 ? false : sqrt(eps(promote_type(typeof(x), typeof(y)))))
    return isapprox(x, y; atol, rtol)
end
function __nonlinearsolve_is_approx(x, y; atol = false,
        rtol = atol > 0 ? false : sqrt(eps(promote_type(eltype(x), eltype(y)))))
    length(x) != length(y) && return false
    d = __maximum_abs(-, x, y)
    return d ≤ max(atol, rtol * max(maximum(abs, x), maximum(abs, y)))
end
