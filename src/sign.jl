#==============================================================================#
# sign.jl
#
# AWS Request Signing.
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


using MbedTLS
using HTTP


function sign!(r::AWSRequest, t = now(Dates.UTC))

    if r[:service] in ["sdb", "importexport"]
        sign_aws2!(r, t)
    else
        sign_aws4!(r, t)
    end
end


# Create AWS Signature Version 2 Authentication query parameters.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-2.html

function sign_aws2!(r::AWSRequest, t)

    uri = URI(r[:url])

    query = Dict{AbstractString,AbstractString}()
    for elem in split(r[:content], '&', keep=false)
        (n, v) = split(elem, "=")
        query[n] = HTTP.unescape(v)
    end

    r[:headers]["Content-Type"] =
        "application/x-www-form-urlencoded; charset=utf-8"

    query["AWSAccessKeyId"] = r[:creds].access_key_id
    query["Expires"] = Dates.format(t + Dates.Second(120),
                                    "yyyy-mm-ddTHH:MM:SSZ")
    query["SignatureVersion"] = "2"
    query["SignatureMethod"] = "HmacSHA256"
    if r[:creds].token != ""
        query["SecurityToken"] = r[:creds].token
    end

    query = Pair[k => query[k] for k in sort(collect(keys(query)))]

    to_sign = "POST\n$(uri.host)\n$(uri.path)\n$(HTTP.escape(query))"

    secret = r[:creds].secret_key
    push!(query, "Signature" =>
                  digest(MD_SHA256, to_sign, secret) |> base64encode |> strip)

    r[:content] = HTTP.escape(query)
end



# Create AWS Signature Version 4 Authentication Headers.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html

function sign_aws4!(r::AWSRequest, t)

    # ISO8601 date/time strings for time of request...
    date = Dates.format(t,"yyyymmdd")
    datetime = Dates.format(t,"yyyymmddTHHMMSSZ")

    # Authentication scope...
    scope = [date, r[:region], r[:service], "aws4_request"]

    # Signing key generated from today's scope string...
    signing_key = string("AWS4", r[:creds].secret_key)
    for element in scope
        signing_key = digest(MD_SHA256, element, signing_key)
    end

    # Authentication scope string...
    scope = join(scope, "/")

    # SHA256 hash of content...
    content_hash = bytes2hex(digest(MD_SHA256, r[:content]))

    # HTTP headers...
    delete!(r[:headers], "Authorization")
    merge!(r[:headers], Dict(
        "x-amz-content-sha256" => content_hash,
        "x-amz-date"           => datetime,
        "Content-MD5"          => base64encode(digest(MD_MD5, r[:content]))
    ))
    if r[:creds].token != ""
        r[:headers]["x-amz-security-token"] = r[:creds].token
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = ["$(lowercase(k)):$(strip(v))" for (k,v) in r[:headers]]
    signed_headers = join(sort([lowercase(k) for k in keys(r[:headers])]), ";")

    # Sort Query String...
    uri = URI(r[:url])
    query = query_params(uri)
    query = Pair[k => query[k] for k in sort(collect(keys(query)))]

    # Create hash of canonical request...
    canonical_form = string(r[:verb], "\n",
                            r[:service] == "s3" ? uri.path
                                                : escape_path(uri.path), "\n",
                            HTTP.escape(query), "\n",
                            join(sort(canonical_headers), "\n"), "\n\n",
                            signed_headers, "\n",
                            content_hash)
    canonical_hash = bytes2hex(digest(MD_SHA256, canonical_form))

    # Create and sign "String to Sign"...
    string_to_sign = "AWS4-HMAC-SHA256\n$datetime\n$scope\n$canonical_hash"
    signature = bytes2hex(digest(MD_SHA256, string_to_sign, signing_key))

    # Append Authorization header...
    r[:headers]["Authorization"] = string(
        "AWS4-HMAC-SHA256 ",
        "Credential=$(r[:creds].access_key_id)/$scope, ",
        "SignedHeaders=$signed_headers, ",
        "Signature=$signature"
    )
end



#==============================================================================#
# End of file.
#==============================================================================#
