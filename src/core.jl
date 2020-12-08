"""
    Report{T<:NamedTuple}

Represents a single report or document. This object has two fields,

* `text::String`
* `metadata::T`

The `text` is automatically processed by first applying the replacements
from [`AUTOMATIC_REPLACEMENTS`](@ref), then replacing punctuation
matching `r"[.!?><\\-]"` by spaces, and  finally by
adding a space to the end of the document.
"""
struct Report{T<:NamedTuple}
    text::String
    metadata::T

    function Report(text::AbstractString, metadata::T) where {T}
        check_keys(T)
        return new{T}(process_report(text), metadata)
    end
end

Report(text::AbstractString) = Report(text, NamedTuple())

function process_report(str::AbstractString)
    # Apply automatic replacements
    # using https://github.com/JuliaLang/julia/issues/29849#issuecomment-449535743
    str = foldl(replace, AUTOMATIC_REPLACEMENTS, init=str)
    # Replace punctuation with a space
    str = process_punct(str)
    # Add a final space to ensure that the last word is recognized
    # as a word boundary.
    str = str * " "
    return str
end

function process_punct(str::AbstractString)
    return replace(str, r"[.!?><\\-]" => " ")
end

abstract type AbstractQuery end

struct Query <: AbstractQuery
    text::String
    Query(str::AbstractString) = new(process_punct(str))
end

function Base.match(Q::Query, R::Report)
    if (length(R.text) < length(Q.text)) || (length(Q.text) == 0)
        return nothing
    end
    inds = findfirst(Q.text, R.text)
    inds === nothing && return nothing
    return QueryMatch(Q, R, 0, inds)
end

function match_all(Q::Query, R::Report)
    if (length(R.text) < length(Q.text)) || (length(Q.text) == 0)
        all_inds = UnitRange[]
    else
        all_inds = findall(Q.text, R.text)
        if all_inds === nothing
            all_inds = UnitRange[]
        end
    end
    return [QueryMatch(Q, R, 0, inds) for inds in all_inds]
end

struct Or{S<:Tuple} <: AbstractQuery
    subqueries::S
end

function Base.match(Q::Or, R::Report)
    for subquery in Q.subqueries
        m = match(subquery, R)
        m !== nothing && return m
    end
    return nothing
end

function match_all(Q::Or, R::Report)
    return reduce(vcat, (match_all(subquery, R) for subquery in Q.subqueries))
end

# Specializations to combine Or's
function Or(q1::Or, q2::AbstractQuery)
    return Or((q1.subqueries..., q2))
end

Or(q1::AbstractQuery, q2::Or) = Or(q2, q1)

function Or(q1::Or, q2::Or)
    return Or((q1.subqueries..., q2.subqueries...))
end

Or(q1::AbstractQuery, q2::AbstractQuery) = Or((q1, q2))

struct And{S<:Tuple} <: AbstractQuery
    subqueries::S
end

# This is type-unstable...
function Base.match(Q::And, R::Report)
    matches = tuple()
    for subquery in Q.subqueries
        m = match(subquery, R)
        m === nothing && return nothing
        matches = (matches..., m)
    end
    return AndMatch(matches)
end

# Specializations to combine And's
And(q1::And, q2::AbstractQuery) = And((q1.subqueries..., q2))
And(q1::AbstractQuery, q2::And) = And((q1, q2.subqueries...))
And(q1::And, q2::And) = And((q1.subqueries..., q2.subqueries...))
And(q1::AbstractQuery, q2::AbstractQuery) = And((q1, q2))

Base.:(|)(q1::AbstractQuery, q2::AbstractQuery) = Or(q1, q2)
Base.:(&)(q1::AbstractQuery, q2::AbstractQuery) = And(q1, q2)

struct FuzzyQuery{D,T} <: AbstractQuery
    text::String
    dist::D
    threshold::T
    function FuzzyQuery(str::AbstractString, dist::D, threshold::T) where {D,T}
        return new{D,T}(process_punct(str), dist, threshold)
    end
end

FuzzyQuery(str::String) = FuzzyQuery(str, DamerauLevenshtein(), 2)


function dist_with_threshold(dist::DamerauLevenshtein, str1, str2, max_dist)
    return DamerauLevenshtein(max_dist)(str1, str2)
end

function dist_with_threshold(dist::Levenshtein, str1, str2, max_dist)
    return Levenshtein(max_dist)(str1, str2)
end

# Maybe to be upstreamed?
# https://github.com/matthieugomez/StringDistances.jl/issues/29

"""
    _findmin(s1, s2, dist::Partial; max_dist) -> d, inds

StringDistances' `Partial(dist)(s1, s2, max_dist)` returns
the value `d`, the closest partial match between the two strings, up to a maximum
distance `max_dist` (if no match is found less than `max_dist`, then
`max_dist+1` is returned). `_findmin` returns the same value, but also
returns the first set of indices at which an optimal partial match was found.
"""
function _findmin(s1, s2, dist::Partial; max_dist)
    s1, s2 = StringDistances.reorder(s1, s2)
    len1, len2 = length(s1), length(s2)
    len1 == len2 && return dist_with_threshold(dist.dist, s1, s2, max_dist), firstindex(s2):lastindex(s2)
    out = max_dist + 1
    len1 == 0 && return out, 1:0
    out_idx = 0
    for (i, x) in enumerate(qgrams(s2, len1))
        curr = dist_with_threshold(dist.dist, s1, x, max_dist)
        out_idx = ifelse(curr < out, i, out_idx)
        out = min(out, curr)
        max_dist = min(out, max_dist)
    end
    return out, nextind(s2, 0, out_idx):nextind(s2, 0, out_idx + len1 - 1)
end

function Base.match(Q::FuzzyQuery, R::Report)
    # We assume the report text is longer than the query text
    length(R.text) < length(Q.text) && return nothing

    dist, inds = _findmin(Q.text, R.text, Partial(Q.dist); max_dist=Q.threshold)
    return dist <= Q.threshold ? QueryMatch(Q, R, dist, inds) : nothing
end

"""
    _findall(s1, s2, dist::Partial; max_dist) -> Vector{Tuple{Int,UnitRange}}

Returns all of the matches within `max_dist` found by `dist`, returning tuples
of the distance along with the indices of the match.
"""
function _findall(s1, s2, dist::Partial; max_dist)
    s1, s2 = StringDistances.reorder(s1, s2)
    len1, len2 = length(s1), length(s2)
    matches = Tuple{Int,UnitRange}[]

    len1 == 0 && return matches

    if len1 == len2
        curr = dist_with_threshold(dist.dist, s1, s2, max_dist)
        if curr <= max_dist
            push!(matches, (curr, firstindex(s2):lastindex(s2)))
        end
        return matches
    end

    for (i, x) in enumerate(qgrams(s2, len1))
        curr = dist_with_threshold(dist.dist, s1, x, max_dist)
        if curr <= max_dist
            inds = nextind(s2, 0, i):nextind(s2, 0, i + len1 - 1)
            push!(matches, (curr, inds))
        end
    end
    return matches
end

# This takes as input all matches and partitions them into runs
# of overlapping matches. Then chooses the best match from each run.
# Let's say there are matches at 1:3, 2:3, 2:4, 4:5 and 6:7
# Then we only have 2 runs, one involving indices 1:5 and one from 6:7
# Note that 1:3 and 4:5 do not intersect, yet they are in the same run.
# (A math way to say this is that we choose the best representative from the equivalence class of connected components).
# Why do it this way? Well, it's the best I thought of so far.
# Another way would be to say "two matches are the same if they share > 50% of the same indices".
# That seems slightly more reasonable (avoding the situation in the example above where 1:3 and 4:5 have no overlap)
# But it's actually hard to do sensibly, since you have have say 1:3, 2:4, 3:5 and 4:6. Then 1:3 and 2:4 share 2 indices,
# and 2:4 and 3:5 share two indices, and 3:5 and 4:6 share two indices. So which do you keep? Could resolve them one at at time left-to-right
# but then you're actually doing the same thing as the "run of connected components" except requiring a 50% overlap and can run into
# the same issue where you discard disconnected matches. For exmaple what if 4:6 is the best match followed by 3:5 then 2:4?
# Then you have 1:3 and 2:4, keep 2:4. Then you have 2:4 and 3:5, keep 3:5. Then
# you have 3:5 and 4:6, keep 4:6. Now we've just chosen the best match from all of them, but didn't keep 1:3 even though it has no overlap with 4:6.
function non_overlapping_matches(matches)
    length(matches) <= 1 && return matches
    non_overlapping_matches = Tuple{Int,UnitRange}[]
    best_curr_match = first(matches)
    inds_so_far = best_curr_match[2]
    for m in matches
        dist, inds = m
        if first(inds) <= last(inds_so_far)
            inds_so_far = first(inds_so_far):last(inds)
            if dist < best_curr_match[1]
                best_curr_match = m
            end
        else
            push!(non_overlapping_matches, best_curr_match)
            best_curr_match = m
            inds_so_far = inds
        end
    end
    push!(non_overlapping_matches, best_curr_match)
    return non_overlapping_matches
end

function match_all(Q::FuzzyQuery, R::Report)
    matches = _findall(Q.text, R.text, Partial(Q.dist); max_dist=Q.threshold)
    matches_no_overlap = non_overlapping_matches(matches)
    return [QueryMatch(Q, R, m...) for m in matches_no_overlap]
end