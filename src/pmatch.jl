# TODO refactor into patch to bring these into Base
"""
Helper for `pmatch`.
"""
function pexec(re,subject,offset,options,match_data)
    rc = ccall((:pcre2_match_8, Base.PCRE.PCRE_LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Cuint, Ptr{Cvoid}, Ptr{Cvoid}),
               re, subject, sizeof(subject), offset, options, match_data, Base.PCRE.MATCH_CONTEXT[])
    # rc == -1 means no match, -2 means partial match.
    rc < -2 && error("PCRE.exec error: $(err_message(rc))")
    rc
end

"""
Variant of `Base.match` that supports partial matches (when `Base.PCRE.PARTIAL_HARD`
is set in `re.match_options`).
"""
function pmatch(re::Regex, str::Union{SubString{String}, String}, idx::Integer, add_opts::UInt32=UInt32(0))
    Base.compile(re)
    opts = re.match_options | add_opts
    # rc == -1 means no match, -2 means partial match.
    rc = pexec(re.regex, str, idx-1, opts, re.match_data)
    if rc == -1 || (rc == -2 && (re.match_options & Base.PCRE.PARTIAL_HARD) == 0)
        return nothing
    end
    ovec = re.ovec
    n = div(length(ovec),2) - 1
    mat = SubString(str, ovec[1]+1, prevind(str, ovec[2]+1))
    cap = Union{Nothing,SubString{String}}[ovec[2i+1] == PCRE.UNSET ? nothing :
                                        SubString(str, ovec[2i+1]+1,
                                                  prevind(str, ovec[2i+2]+1)) for i=1:n]
    off = Int[ ovec[2i+1]+1 for i=1:n ]
    RegexMatch(mat, cap, ovec[1]+1, off, re)
end

pmatch(r::Regex, s::AbstractString) = pmatch(r, s, firstindex(s))
pmatch(r::Regex, s::AbstractString, i::Integer) = throw(ArgumentError(
    "regex matching is only available for the String type; use String(s) to convert"
))

"""
Constructs a regular expression to perform partial matching.
"""
partial(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS | Base.PCRE.PARTIAL_HARD)

"""
Constructs a regular expression to perform exact maching.
"""
exact(str::AbstractString) = Regex(str)
