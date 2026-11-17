class SlackClient {
    [string]$token

    [hashtable]$headers = @{}

    [string]$BaseUri = 'https://slack.com/api/'

    [string]$psEdition

    SlackClient([securestring]$token) {
        # PtrToStringBSTR (not PtrToStringAuto) - correct on both Windows and Linux
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
        try {
            $this.token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $this.headers = @{
            Authorization = "Bearer $($this.Token)"
        }

        $this.psEdition = & {
            $ExecutionContext.InvokeCommand.ExpandString('$PSVersionTable.PSEdition')
        }
    }

    [pscustomobject]PostCard([string]$Channel, [hashtable[]]$Blocks, [string]$FallBackText) {
        $body = @{
            channel = $Channel
            blocks  = $Blocks
            text    = $FallBackText
        } | ConvertTo-Json -Depth 10 -Compress
        $r = $this._SendAPI('chat.postMessage', $body, 'Post')

        return $r
    }

    [pscustomobject]PostText([string]$channel, [string]$message) {
        $body = @{
            channel = $channel
            text    = $message
        } | ConvertTo-Json -Depth 5

        $r = $this._SendAPI('chat.postMessage', $body, 'Post')
        return $r
    }

    [pscustomobject]_SendAPI([string]$Function, [string]$Method) {
        $uri = "$($this.BaseUri)$Function"

        $params = @{
            Uri         = $uri
            Method      = $Method
            Headers     = $this.headers
            ContentType = 'application/json; charset=utf-8'
        }

        if ($this.psEdition -and $this.psEdition -eq 'Core') {
            $params.Add('MaximumRetryCount',3)
            $params.Add('RetryIntervalSec',5)
        }
        $r = Invoke-RestMethod @params
        return $r
    }

    [pscustomobject]_SendAPI([string]$Function, [string]$Body, [string]$Method) {
        $uri = "$($this.BaseUri)$Function"

        $params = @{
            Uri               = $uri
            Method            = $Method
            Headers           = $this.headers
            Body              = $body
            ContentType       = 'application/json; charset=utf-8'
        }

        if ($this.psEdition -and $this.psEdition -eq 'Core') {
            $params.Add('MaximumRetryCount',3)
            $params.Add('RetryIntervalSec',5)
        }

        $r = Invoke-RestMethod @params
        return $r
    }

    [pscustomobject]UploadFileToChannel([string]$Channel, [string]$FilePath, [string]$FileName) {
        return $this.UploadFileToChannel($Channel, $FilePath, $FileName, [string]::Empty)
    }

    # Upload flow (files.upload is retired):
    #   1. files.getUploadURLExternal (POST, form-urlencoded: filename, length) -> upload_url, file_id
    #   2. POST raw bytes to upload_url (HTTP 200 = ok)
    #   3. files.completeUploadExternal (files[], channel_id, optional thread_ts = PARENT ts)
    # $Channel must be a conversation ID (C.../G.../D...), not a user ID.
    [pscustomobject]UploadFileToChannel([string]$Channel, [string]$FilePath, [string]$FileName, [string]$ThreadTs) {

        $file = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        if ([string]::IsNullOrEmpty($FileName)) {
            $FileName = $file.Name
        }

        # 1. Get URL to upload file to
        $body = @{
            filename = $file.Name
            length   = $file.Length
        }
        $r = Invoke-RestMethod -Uri "$($this.BaseUri)files.getUploadURLExternal" -Body $body -Method Post -ContentType 'application/x-www-form-urlencoded; charset=utf-8' -Headers $this.headers
        if (-not $r.ok) {
            throw "files.getUploadURLExternal failed: $($r.error)"
        }
        $uploadUrl = $r.upload_url
        $fileId = $r.file_id

        # 2. Upload bytes
        $u = Invoke-WebRequest -Uri $uploadUrl -Method Post -InFile $file.FullName -Headers $this.headers -ContentType 'application/octet-stream' -UseBasicParsing
        if ($u.StatusCode -ne 200) {
            throw "Upload to upload_url failed: $($u.StatusCode) $($u.StatusDescription)"
        }

        # 3. Share file with channel (and thread)
        $complete = @{
            files      = @(
                @{
                    id    = $fileId
                    title = $FileName
                }
            )
            channel_id = $Channel
        }
        if (-not [string]::IsNullOrEmpty($ThreadTs)) {
            $complete.thread_ts = $ThreadTs
        }
        $r = $this._SendAPI('files.completeUploadExternal', ($complete | ConvertTo-Json -Depth 5 -Compress), 'Post')
        if (-not $r.ok) {
            throw "files.completeUploadExternal failed: $($r.error)"
        }
        return $r
    }
}
