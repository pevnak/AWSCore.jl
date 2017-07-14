#==============================================================================#
# AWSCredentials.jl
#
# Load AWS Credentials from:
# - EC2 Instance Profile,
# - Environment variables, or
# - ~/.aws/credentials file.
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#

export AWSCredentials,
       localhost_is_lambda,
       localhost_is_ec2,
       aws_user_arn,
       aws_account_number

"""
When you interact with AWS, you specify your [AWS Security Credentials](http://docs.aws.amazon.com/general/latest/gr/aws-security-credentials.html) to verify who you are and whether you have permission to access the resources that you are requesting. AWS uses the security credentials to authenticate and authorize your requests.

The fields `access_key_id` and `secret_key` hold the access keys used to authenticate API requests (see [Creating, Modifying, and Viewing Access Keys](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html#Using_CreateAccessKey)).

[Temporary Security Credentials](http://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html) require the extra session `token` field.


The `user_arn` and `account_number` fields are used to cache the result of the [`aws_user_arn`](@ref) and [`aws_account_number`](@ref) functions.

The `AWSCredentials()` constructor tries to load local Credentials from
environment variables, `~/.aws/credentials` or EC2 instance credentials. 
"""

type AWSCredentials
    access_key_id::String
    secret_key::String
    token::String
    user_arn::String
    account_number::String

    function AWSCredentials(access_key_id, secret_key,
                            token="", user_arn="", account_number="")
        new(access_key_id, secret_key, token, user_arn, account_number)
    end
end

function Base.show(io::IO,c::AWSCredentials)
    println(io, string(c.user_arn,
                       c.user_arn == "" ? "" : " ",
                       "(",
                       c.account_number,
                       c.access_key_id,
                       c.secret_key == "" ? "" : ", $(c.secret_key[1:3])...",
                       c.token == "" ? "" : ", $(c.token[1:3])..."),
                       ")")
end


function AWSCredentials()

    if haskey(ENV, "AWS_ACCESS_KEY_ID")

        aws = env_instance_credentials()

    elseif isfile(dot_aws_credentials_file())

        aws = dot_aws_credentials()

    elseif localhost_is_ec2()

        aws = ec2_instance_credentials()
    else
        error("Can't find AWS credentials!")
    end

    if debug_level > 0
        display(aws)
    end

    return aws
end


"""
Is Julia running in an AWS Lambda sandbox?
"""

localhost_is_lambda() = haskey(ENV, "LAMBDA_TASK_ROOT")


"""
Is Julia running on an EC2 virtual machine?
"""

function localhost_is_ec2()

    if localhost_is_lambda()
        return false
    end

    @static if is_unix()
        return isfile("/sys/hypervisor/uuid") &&
               String(read("/sys/hypervisor/uuid",3)) == "ec2"
    end

    return false
end


"""
    aws_user_arn(::AWSConfig)

Unique
[Amazon Resource Name]
(http://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html)
for configrued user.

e.g. `"arn:aws:iam::account-ID-without-hyphens:user/Bob"`
"""

function aws_user_arn(aws::AWSConfig)

    creds = aws[:creds]

    if creds.user_arn == ""

        r = do_request(post_request(aws, "sts", "2011-06-15",
                                    Dict("Action" => "GetCallerIdentity",
                                         "ContentType" => "JSON")))
        creds.user_arn = r["Arn"]
        creds.account_number = r["Account"]
    end

    return creds.user_arn
end


"""
    aws_account_number(::AWSConfig)

12-digit [AWS Account Number](http://docs.aws.amazon.com/general/latest/gr/acct-identifiers.html).
"""

function aws_account_number(aws::AWSConfig)
    creds = aws[:creds]
    if creds.account_number == ""
        aws_user_arn(aws)
    end
    return creds.account_number
end


"""
    ec2_metadata(key)

Fetch [EC2 meta-data]
(http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)
for `key`.
"""

function ec2_metadata(key)

    @assert localhost_is_ec2()

    bytestring(http_request("169.254.169.254", "/latest/meta-data/$key").data)
end


using JSON

"""
Load [Instance Profile Credentials]
(http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials)
for EC2 virtual machine.
"""

function ec2_instance_credentials()

    @assert localhost_is_ec2()

    info  = ec2_metadata("iam/info")
    info  = JSON.parse(info, dicttype=Dict{String,String})

    name  = ec2_metadata("iam/security-credentials/")
    creds = ec2_metadata("iam/security-credentials/$name")
    new_creds = JSON.parse(creds, dicttype=Dict{String,String})

    if debug_level > 0
        print("Loading AWSCredentials EC2 metadata... ")
    end

    AWSCredentials(new_creds["AccessKeyId"],
                   new_creds["SecretAccessKey"],
                   new_creds["Token"],
                   info["InstanceProfileArn"])
end


"""
Load Credentials from [environment variables]
(http://docs.aws.amazon.com/cli/latest/userguide/cli-environment.html)
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` etc.
(e.g. in Lambda sandbox).
"""

function env_instance_credentials()

    if debug_level > 0
        print("Loading AWSCredentials from ENV[\"AWS_ACCESS_KEY_ID\"]... ")
    end

    AWSCredentials(ENV["AWS_ACCESS_KEY_ID"],
                   ENV["AWS_SECRET_ACCESS_KEY"],
                   get(ENV, "AWS_SESSION_TOKEN", ""),
                   get(ENV, "AWS_USER_ARN", ""))
end


using IniFile

dot_aws_credentials_file() = get(ENV, "AWS_CONFIG_FILE",
                                 joinpath(homedir(), ".aws", "credentials"))

"""
Load Credentials from [AWS CLI ~/.aws/credentials file]
(http://docs.aws.amazon.com/cli/latest/userguide/cli-config-files.html).
"""

function dot_aws_credentials()

    @assert isfile(dot_aws_credentials_file())

    ini = read(Inifile(), dot_aws_credentials_file())

    profile = get(ENV, "AWS_DEFAULT_PROFILE", "default")

    if debug_level > 0
        print("Loading \"$profile\" AWSCredentials from " *
                dot_aws_credentials_file() * "... ")
    end

    AWSCredentials(get(ini, profile, "aws_access_key_id"),
                   get(ini, profile, "aws_secret_access_key"))
end



#==============================================================================#
# End of file.
#==============================================================================#
