<#
.SYNOPSIS
    Executes an AI-Powered Code Review against an Azure DevOps Pull Request using Azure AI Foundry / OpenAI.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$LlmEndpoint,

    [Parameter(Mandatory=$true)]
    [string]$Model,

    [Parameter(Mandatory=$true)]
    [string]$SystemPromptPath,

    [Parameter(Mandatory=$true)]
    [string]$RulesFilePath,

    [Parameter(Mandatory=$true)]
    [string]$FileExclusions,

    [Parameter(Mandatory=$false)]
    [int]$Temperature = 0
)

# Authentication token from Azure DevOps pipeline environment
$AdoToken = $env:SYSTEM_ACCESSTOKEN
if (-not $AdoToken) {
    Write-Error "SYSTEM_ACCESSTOKEN environment variable is missing. Ensure the pipeline task has access to the token."
    exit 1
}

# Authentication for LLM
$LlmApiKey = $env:LLM_API_KEY # Assumed to be injected via pipeline secrets

$repoId = $env:BUILD_REPOSITORY_ID
$prId = $env:SYSTEM_PULLREQUEST_PULLREQUESTID
$orgUri = $env:SYSTEM_COLLECTIONURI
$project = $env:SYSTEM_TEAMPROJECT

if (-not $prId) {
    Write-Host "Not a Pull Request. Skipping AI Code Review."
    exit 0
}

Write-Host "Starting AI Code Review for PR $prId"
Write-Host "Target Model: $Model"

# 1. Fetch Git Diff
$targetBranch = $env:SYSTEM_PULLREQUEST_TARGETBRANCH
# Exclude files using regex pattern matching
$excludePattern = $FileExclusions -replace '\s', '' -replace ',', '|' -replace '\*', '.*' -replace '\.', '\.'
Write-Host "Excluding files matching: $excludePattern"

$diffOutput = git diff "origin/$targetBranch...HEAD" 
if ($excludePattern) {
    $diffOutput = $diffOutput | Select-String -NotMatch $excludePattern
}
$diffContent = $diffOutput -join "`n"

if ([string]::IsNullOrWhiteSpace($diffContent)) {
    Write-Host "No valid changes found to review."
    exit 0
}

# 2. Read Prompts and Rules
$systemPrompt = Get-Content -Path $SystemPromptPath -Raw
$rules = Get-Content -Path $RulesFilePath -Raw
$fullSystemPrompt = "$systemPrompt`n`n### CUSTOM TEAM RULES ###`n$rules"

# 3. Deduplication: Fetch existing active PR Threads
$authHeader = @{ Authorization = "Bearer $AdoToken" }
$threadsUrl = "$orgUri$project/_apis/git/repositories/$repoId/pullRequests/$prId/threads?api-version=7.0"

try {
    $existingThreads = Invoke-RestMethod -Uri $threadsUrl -Headers $authHeader -Method Get
} catch {
    Write-Warning "Failed to retrieve existing PR threads. Deduplication may not work."
    $existingThreads = @{ value = @() }
}

$existingComments = @()
foreach ($thread in $existingThreads.value) {
    if ($thread.status -ne 'closed' -and $thread.status -ne 'fixed') {
        foreach ($comment in $thread.comments) {
            $existingComments += $comment.content
        }
    }
}

# 4. Call LLM API with strict JSON schema
$schema = @{
    type = "object"
    properties = @{
        reviews = @{
            type = "array"
            items = @{
                type = "object"
                properties = @{
                    filePath = @{ type = "string"; description = "Path to the file" }
                    lineNumber = @{ type = "integer"; description = "Line number" }
                    severity = @{ type = "string"; enum = @("High", "Medium", "Low") }
                    comment = @{ type = "string"; description = "Actionable feedback" }
                }
                required = @("filePath", "lineNumber", "severity", "comment")
                additionalProperties = $false
            }
        }
    }
    required = @("reviews")
    additionalProperties = $false
}

$body = @{
    model = $Model
    temperature = $Temperature
    response_format = @{
        type = "json_schema"
        json_schema = @{
            name = "code_review_schema"
            strict = $true
            schema = $schema
        }
    }
    messages = @(
        @{ role = "system"; content = $fullSystemPrompt },
        @{ role = "user"; content = "Review the following git diff:`n`n$diffContent" }
    )
}

$llmHeaders = @{
    "Content-Type" = "application/json"
    "api-key" = $LlmApiKey
}

try {
    Write-Host "Calling LLM Azure AI Foundry API..."
    $response = Invoke-RestMethod -Uri $LlmEndpoint -Headers $llmHeaders -Method Post -Body ($body | ConvertTo-Json -Depth 10)
    $jsonResponse = $response.choices[0].message.content
    $aiResult = $jsonResponse | ConvertFrom-Json
} catch {
    Write-Error "Failed to call LLM: $_"
    exit 1
}

$hasHighSeverity = $false

# 5. Post Inline Comments to ADO
foreach ($review in $aiResult.reviews) {
    $commentText = "**[AI Code Review - $($review.severity)]** $($review.comment)"

    if ($existingComments -contains $commentText) {
        Write-Host "Skipping duplicate comment on $($review.filePath):$($review.lineNumber)"
        continue
    }

    if ($review.severity -eq "High") {
        $hasHighSeverity = $true
    }

    $threadBody = @{
        comments = @(
            @{
                parentCommentId = 0
                content = $commentText
                commentType = 1
            }
        )
        status = "active"
        threadContext = @{
            filePath = "/$($review.filePath)"
            rightFileStart = @{ line = $review.lineNumber; offset = 1 }
            rightFileEnd = @{ line = $review.lineNumber; offset = 2 }
        }
    }

    Write-Host "Posting comment to $($review.filePath) at line $($review.lineNumber)"
    try {
        Invoke-RestMethod -Uri $threadsUrl -Headers $authHeader -Method Post -Body ($threadBody | ConvertTo-Json -Depth 10) -ContentType "application/json"
    } catch {
        Write-Warning "Failed to post thread for $($review.filePath): $_"
    }
}

if ($hasHighSeverity) {
    Write-Error "AI Code Review detected HIGH severity issues. Failing the pipeline."
    exit 1
}

Write-Host "AI Code Review completed successfully."
exit 0
