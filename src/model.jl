# We assume a model is just a callable object (https://docs.julialang.org/en/v1/manual/methods/#Function-like-objects-1)
# model(x) will give us a prediction, and params(model) will iterate over the parameters.

"""
    param(array; atype)
    param(dims...; init, atype)
    param0(dims...; atype)

The first form returns `Param(atype(array))` where `atype=identity` is the default.

The second form Returns a randomly initialized `Param(atype(init(dims...)))`.
By default, `init` is `xavier` and `atype` is `KnetArray{Float32}` if `gpu() >= 0`,
otherwise `Array{Float32}`. 

The third form `param0` is an alias for `param(dims...; init=zeros)`.
"""
param,param0

param(x::Union{Array,KnetArray}; atype=identity) = Param(atype(x))
param(d...; init=xavier, atype=atype())=Param(atype(init(d...)))
param0(d...; atype=atype())=param(d...; init=zeros, atype=atype)
atype()=(gpu() >= 0 ? KnetArray{Float32} : Array{Float32})

# Keyword argument problem:
# optimizer, loss, model can all take keyword args; how do we specify them through train?
# We can give a constructed optimizer and deepcopy it for each param.
# We don't call model directly, only through loss (because it may need model params for regularization).
# So we pass all unrecognized kwargs to loss and let it sort out.
if isdefined(AutoGrad,:gradient); @eval begin #TODO: remove when AutoGrad 1.1 released

"""
    train!(model, data; loss, optimizer, callback, o...)

Train a model with given data.

* `model`: A callable object. `model(x; o...)` should return a prediction. `params(model)`
   will automatically iterate over model parameters.
* `data`: An iterator. `for (x,y) in data` should iterate over input-output pairs.
* `loss=nll`: A loss function, called with `loss(model,x,y; o...)`.
* `optimizer=SGD()`: An optimizer object that will be copied for each parameter and used by
  `[update!]`(@ref).
* `callback`: To facilitate reporting and termination, a callback function is called
   before every update with `callback(model,x,y,loss)`. Training continues if the return value
   is true, terminates if it is false.  See the [`Train`](@ref) object as an example
   callback. The default callback quits after one epoch.
* Other keyword arguments will be passed to `loss` and possibly by `loss` to `model`.
"""
function train!(model, data; loss=nll, optimizer=SGD(), callback=ncount(length(data)), o...)
    for param in params(model)
        param.opt = deepcopy(optimizer)
    end
    while true
        for (x,y) in data
            J = @diff loss(model,x,y; o...)
            if !callback(model,x,y,value(J)); return; end
            update!(model, J)
        end
    end
end

function update!(model,J::Tape)
    for w in params(model)
        g = gradient(J,w)
        update!(value(w),g,w.opt)
    end
end
end; end

ncount(n)=((x...)->(n > 0 && (n -= 1; true)))

import ProgressMeter            # don't want to import update!

"""
    Train(howlong, datasets...)

Create a callback function that can be used with [`train!`](@ref).

`howlong` can be an integer, an array of integers, or a `StepRange` such as 0:100:1000
representing the number of updates for reporting, testing and termination. The training will
terminate when the number of updates reach howlong[end]. So the simplest use would be
`Train(n::Int)` which will cause training to terminate after `n` updates.  If the update
count ∈ howlong, a progress bar will be updated and the model will be tested on the datasets
if any are provided. For example `Train(0:100:1000,dtst)` will update the progress bar and
calculate loss and error on dtst every 100 updates and terminate at 1000 updates.  The
`losses` and `errors` fields of the `Train` object will contain the results of these tests.

"""
mutable struct Train
    whentorecord; datasets; losses; errors; updatecount; progress
    Train(w,ds...)=new(w, ds, [Float64[] for d in ds], [Float64[] for d in ds], 0, ProgressMeter.Progress(w[end],1))
end

function (t::Train)(model,x,y,loss)
    if t.updatecount ∈ t.whentorecord
        ProgressMeter.update!(t.progress, t.updatecount)
        for (data,loss,err) in zip(t.datasets, t.losses, t.errors)
            push!(loss, nll(model,data))
            push!(err, zeroone(model,data))
        end
    end
    t.updatecount += 1
    return t.updatecount <= t.whentorecord[end]
end


# params(f) Based on deepcopy_internal:

"Return an array of Params found by a recursive search of the given object."
params(f) = (ps=Param[]; params_internal(f,ps,IdDict()); ps)

params_internal(p::Param, ps::Vector{Param}, d::IdDict) = if !haskey(d,p); d[p]=true; push!(ps,p); end

params_internal(x::Union{Symbol,Core.MethodInstance,Method,GlobalRef,DataType,Union,Task},
                ps::Vector{Param}, stackdict::IdDict) = return
params_internal(x::Tuple, ps::Vector{Param}, stackdict::IdDict) =
    for p in x; params_internal(p, ps, stackdict); end

params_internal(x::Module, ps::Vector{Param}, stackdict::IdDict) = return

params_internal(x::String, ps::Vector{Param}, stackdict::IdDict) = return

function params_internal(x::Core.SimpleVector, ps::Vector{Param}, stackdict::IdDict)
    if haskey(stackdict, x)
        return
    end
    stackdict[x] = true
    for p in x; params_internal(x, ps, stackdict); end
end

function params_internal(@nospecialize(x), ps::Vector{Param}, stackdict::IdDict)
    T = typeof(x)::DataType
    nf = nfields(x)
    (isbitstype(T) || nf == 0) && return
    if haskey(stackdict, x)
        return
    end
    if T.mutable
        stackdict[x] = true
    end
    for i in 1:nf
        if isdefined(x,i)
            params_internal(getfield(x,i), ps, stackdict)
        end
    end
end

function params_internal(x::Array, ps::Vector{Param}, stackdict::IdDict)
    if haskey(stackdict, x)
        return
    end
    _params_array_t(x, eltype(x), ps, stackdict)
end

function _params_array_t(@nospecialize(x), T, ps::Vector{Param}, stackdict::IdDict)
    stackdict[x] = true
    if isbitstype(T)
        return
    end
    for i = 1:(length(x)::Int)
        if ccall(:jl_array_isassigned, Cint, (Any, Csize_t), x, i-1) != 0
            xi = ccall(:jl_arrayref, Any, (Any, Csize_t), x, i-1)
            if !isbits(xi)
                xi = params_internal(xi, ps, stackdict)
            end
        end
    end
end

function params_internal(x::Union{Dict,IdDict}, ps::Vector{Param}, stackdict::IdDict)
    if haskey(stackdict, x)
        return
    end
    stackdict[x] = true
    for (k, v) in x
        params_internal(k, ps, stackdict)
        params_internal(v, ps, stackdict)
    end
end
