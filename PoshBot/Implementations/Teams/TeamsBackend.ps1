
class TeamsBackend : Backend {

    [bool]$LazyLoadUsers = $true

    # The types of message that we care about from Teams
    # All othere will be ignored
    [string[]]$MessageTypes = @(
        'message'
    )

    [string]$TeamId = $null
    [string]$ServiceUrl = 'https://smba.trafficmanager.net/amer/'
    [string]$BotId = $null
    [string]$BotName = $null
    [string]$TenantId = $null
    [bool]$Initialized = $false

    [hashtable]$DMConverations = @{}

    [hashtable]$FileUploadTracker = @{}

    # A cache miss reloads the user list at most once per this interval (a reload blocks the bot loop)
    [int]$UserReloadMinIntervalSeconds = 60
    [int]$RoomReloadMinIntervalSeconds = 60
    [int]$UnknownRoomTtlMinutes = 10
    hidden [datetime]$_LastUserLoad = [datetime]::MinValue
    hidden [datetime]$_LastRoomLoad = [datetime]::MinValue

    # Users we learned from incoming messages (not in the bulk member list). Persisted to LearnedTeamsUsers.xml
    hidden [hashtable]$_LearnedUsers = @{}
    hidden [bool]$_LearnedUsersLoaded = $false

    # Conversation IDs that are not channels of the team (bot id, personal chats ...): id -> when we last failed to resolve it
    hidden [hashtable]$_UnknownRooms = @{}

    TeamsBackend([TeamsConnectionConfig]$Config) {
        $conn = [TeamsConnection]::new($Config)
        $this.TeamId = $Config.TeamId
        $this.Connection = $conn
    }

    # Connect to Teams
    [void]Connect() {
        $this.LogInfo('Connecting to backend')
        $this.Connection.Connect()
    }

    [Message[]]ReceiveMessage() {
        $messages = New-Object -TypeName System.Collections.ArrayList
        try {
            # Read the output stream from the receive thread and get any messages since our last read
            $jsonResults = $this.Connection.ReadReceiveThread()

            if (-not [string]::IsNullOrEmpty($jsonResults)) {

                foreach ($jsonResult in $jsonResults) {

                    $this.LogDebug('Received message', $jsonResult)

                    $teamsMessages = @($jsonResult | ConvertFrom-Json)

                    if (-not $this.Initialized -and $teamsMessages.Count -gt 0) {
                        $this.DelayedInit($teamsMessages[0])
                    }

                    foreach ($teamsMessage in $teamsMessages) {

                        # We only care about certain message types from Teams
                        if ($teamsMessage.type -in $this.MessageTypes) {
                            $msg = [Message]::new()

                            switch ($teamsMessage.type) {
                                'message' {
                                    $msg.Type = [MessageType]::Message
                                    break
                                }
                            }
                            $this.LogDebug("Message type is [$($msg.Type)]")

                            $msg.Id = $teamsMessage.id
                            if ($teamsMessage.recipient) {
                                $msg.To = $teamsMessage.recipient.id
                            }

                            $msg.RawMessage = $teamsMessage
                            $this.LogDebug('Raw message', $teamsMessage)

                            if ($teamsMessage.text) {
                                # When commands are directed to PoshBot, the bot must be "at" mentioned.
                                # This will show up in the text of the message received. We don't need it so strip it out.
                                $msg.Text = $teamsMessage.text.Replace("<at>$($this.Connection.Config.BotName)</at> ", '') -Replace '\n', ''

                                # When text is pasted into Teams it pads the text with newlines. Strip those out so we can parse the message correctly
                                $msg.Text = $msg.Text -Replace '\n', '' -Replace '\r', ''
                            }

                            if ($teamsMessage.from) {
                                $msg.From = $teamsMessage.from.id
                                $msg.FromName = $teamsMessage.from.name

                                # The sender may be missing from the bulk member list (guest, new employee, other tenant).
                                # Learn them from the message itself so commands still get a usable CallingUserInfo.
                                try {
                                    $this._EnsureUser($teamsMessage)
                                } catch {
                                    $this.LogInfo([LogSeverity]::Warning, "Unable to register user [$($teamsMessage.from.id)]", [ExceptionFormatter]::Summarize($_))
                                }
                            }

                            # Mark as DM
                            # 'team' data is not passed in channel conversations
                            # so we can use it to determine if message is in personal chat
                            # https://docs.microsoft.com/en-us/microsoftteams/platform/concepts/bots/bot-conversations/bots-conversations#teams-channel-data
                            if (-not $teamsMessage.channelData.team) {
                                $msg.IsDM = $true
                                $msg.ToName = $this.Connection.Config.BotName
                            } else {
                                if ($msg.To) {
                                    $msg.ToName = $this.ResolveToName($msg)
                                }
                            }

                            # Resolve channel name
                            # Skip DM channels, they won't have names
                            if (($teamsMessage.channelData.teamsChannelId) -and (-not $msg.IsDM)) {
                                $msg.ToName = $this.ChannelIdToName($teamsMessage.channelData.teamsChannelId)
                            }

                            # Get time of message
                            $msg.Time = [datetime]$teamsMessage.timestamp

                            $messages.Add($msg) > $null
                        } else {
                            $this.LogDebug("Message type is [$($teamsMessage.type)]. Ignoring")
                        }
                    }
                }
            }
        } catch {
            $this.LogInfo([LogSeverity]::Error, 'Error receiving messages from Teams', [ExceptionFormatter]::Summarize($_))
        }

        return $messages
    }

    [void]Ping() {}

    # Send a message
    [void]SendMessage([Response]$Response) {

        $baseUrl = $Response.OriginalMessage.RawMessage.serviceUrl
        $fromId = $Response.OriginalMessage.RawMessage.from.id
        $fromName = $Response.OriginalMessage.RawMessage.from.name
        $recipientId = $Response.OriginalMessage.RawMessage.recipient.id
        $recipientName = $Response.OriginalMessage.RawMessage.recipient.name
        $conversationId = $Response.OriginalMessage.RawMessage.conversation.id
        $activityId = $Response.OriginalMessage.RawMessage.id
        $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/$activityId"
        $headers = @{
            Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)"
        }

        # Process any custom responses
        $this.LogDebug("[$($Response.Data.Count)] custom responses")
        foreach ($customResponse in $Response.Data) {

            if ($customResponse.Text) {
                #$customResponse.Text = $this._RepairText($customResponse.Text)
            }

            # Redirect response to DM channel if told to
            if ($customResponse.DM) {
                $conversationId = $this._CreateDMConversation($Response.OriginalMessage.RawMessage.from.id)
                $activityId = $conversationId
                $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/"
            }

            switch -Regex ($customResponse.PSObject.TypeNames[0]) {
                '(.*?)PoshBot\.Card\.Response' {
                    $this.LogDebug('Custom response is [PoshBot.Card.Response]')

                    $cardBody = @{
                        type         = 'message'
                        from         = @{
                            id   = $fromId
                            name = $fromName
                        }
                        conversation = @{
                            id = $conversationId
                        }
                        recipient    = @{
                            id   = $recipientId
                            name = $recipientName
                        }
                        attachments  = @(
                            @{
                                contentType = 'application/vnd.microsoft.teams.card.o365connector'
                                content     = @{
                                    '@type'    = 'MessageCard'
                                    '@context' = 'http://schema.org/extensions'
                                    themeColor = $customResponse.Color -replace '#', ''
                                    sections   = @(
                                        @{

                                        }
                                    )
                                }
                            }
                        )
                        replyToId    = $activityId
                    }

                    # Thumbnail
                    if ($customResponse.ThumbnailUrl) {
                        $cardBody.attachments[0].content.sections[0].activityImageType = 'article'
                        $cardBody.attachments[0].content.sections[0].activityImage = $customResponse.ThumbnailUrl
                    }

                    # Title
                    if ($customResponse.Title) {
                        $cardBody.attachments[0].content.summary = $customResponse.Title
                        if ($customResponse.LinkUrl) {
                            $cardBody.attachments[0].content.title = "[$($customResponse.Title)]($($customResponse.LinkUrl))"
                        } else {
                            $cardBody.attachments[0].content.title = $customResponse.Title
                        }
                    }

                    # TextBlock
                    if ($customResponse.Text) {
                        $cardBody.attachments[0].content.sections[0].text = '<pre>' + $customResponse.Text + '</pre>'
                        $cardBody.attachments[0].content.sections[0].textFormat = 'markdown'
                    }

                    # Facts
                    if ($customResponse.Fields.Count -gt 0) {
                        $cardBody.attachments[0].content.sections[0].facts = @()
                        foreach ($field in $customResponse.Fields.GetEnumerator()) {
                            $cardBody.attachments[0].content.sections[0].facts += @{
                                name  = $field.Name
                                value = $field.Value.ToString()
                            }
                        }
                    }

                    # Prepend image if needed
                    if ($customResponse.ImageUrl) {
                        $cardBody.attachments[0].content.sections = @(
                            @{
                                images = @(
                                    @{
                                        image = $customResponse.ImageUrl
                                    }
                                )
                            }
                        ) + $cardBody.attachments[0].content.sections
                    }

                    $body = $cardBody | ConvertTo-Json -Depth 20
                    Write-Verbose $body
                    # $body | Out-File -FilePath "$script:moduleBase/responses.json" -Append
                    $this.LogDebug("Sending response back to Teams conversation [$conversationId]", $body)
                    try {
                        $responseParams = @{
                            Uri         = $responseUrl
                            Method      = 'Post'
                            Body        = $body
                            ContentType = 'application/json;charset=utf-8'
                            Headers     = $headers
                        }
                        Invoke-RestMethod @responseParams
                    } catch {
                        $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                    }

                    break
                }
                '(.*?)PoshBot\.Text\.Response' {
                    $this.LogDebug('Custom response is [PoshBot.Text.Response]')

                    $textFormat = 'plain'
                    $cardText = $customResponse.Text
                    if ($customResponse.AsCode) {
                        $textFormat = 'markdown'
                        $cardText = '<pre>' + $cardText + '</pre>'
                    }

                    $cardBody = @{
                        type         = 'message'
                        from         = @{
                            id   = $fromId
                            name = $fromName
                        }
                        conversation = @{
                            id = $conversationId
                        }
                        recipient    = @{
                            id   = $recipientId
                            name = $recipientName
                        }
                        text         = $cardText
                        textFormat   = $textFormat
                        # attachments = @(
                        #     @{
                        #         contentType = 'application/vnd.microsoft.teams.card.o365connector'
                        #         content = @{
                        #             "@type" = 'MessageCard'
                        #             "@context" = 'http://schema.org/extensions'
                        #             text = $cardText
                        #             textFormat = $textFormat
                        #         }
                        #     }
                        # )
                        replyToId    = $activityId
                    }

                    $body = $cardBody | ConvertTo-Json -Depth 15
                    Write-Verbose $body
                    # $body | Out-File -FilePath "$script:moduleBase/responses.json" -Append
                    $this.LogDebug("Sending response back to Teams channel [$conversationId]", $body)
                    try {
                        $responseParams = @{
                            Uri         = $responseUrl
                            Method      = 'Post'
                            Body        = $body
                            ContentType = 'application/json;charset=utf-8'
                            Headers     = $headers
                        }
                        Invoke-RestMethod @responseParams
                    } catch {
                        $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                    }

                    break
                }
                '(.*?)PoshBot\.File\.Upload' {
                    # Teams documentation: https://docs.microsoft.com/en-us/microsoftteams/platform/concepts/bots/bots-files
                    $this.LogDebug('Custom response is [PoshBot.File.Upload]')

                    # Teams doesn't support generic file uploads yet :(
                    # Send a message informing the user of this sad fact
                    $jsonResponse = @{
                        type         = 'message'
                        from         = @{
                            id   = $recipientId
                            name = $recipientName
                        }
                        conversation = @{
                            id   = $conversationId
                            name = ''
                        }
                        recipient    = @{
                            id   = $fromId
                            name = $fromName
                        }
                        text         = "I don't know how to upload files to Teams yet but I'm learning."
                        replyToId    = $activityId
                    } | ConvertTo-Json

                    # $jsonResponse | Out-File -FilePath "$script:moduleBase/responses.json" -Append
                    $this.LogDebug("Sending response back to Teams conversation [$conversationId]")
                    try {
                        $responseParams = @{
                            Uri         = $responseUrl
                            Method      = 'Post'
                            Body        = $jsonResponse
                            ContentType = 'application/json;charset=utf-8'
                            Headers     = $headers
                        }
                        Invoke-RestMethod @responseParams
                    } catch {
                        $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                    }

                    # # Get details about file to upload
                    # $fileToUpload = @{
                    #     Path      = $customResponse.Path
                    #     Name      = Split-Path -Path $customResponse.Path -Leaf
                    #     Size      = (Get-Item -Path $customResponse.Path).Length
                    #     ConsentId = [guid]::NewGuid().ToString()
                    # }
                    # if (-not [string]::IsNullOrEmpty($customResponse.Title)) {
                    #     $fileToUpload.Description = $customResponse.Title
                    # } else {
                    #     $fileToUpload.Description = $fileToUpload.Name
                    # }

                    # Teams doesn't support file uploads to group channels (lame)
                    # Setup a private DM session with the user so we can send the
                    # file consent card
                    # $conversationId = $this._CreateDMConversation($Response.OriginalMessage.RawMessage.from.id)
                    # $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/"

                    # $fileConsentRequest = @{
                    #     type = 'message'
                    #     from = @{
                    #         id = $recipientId
                    #         name = $recipientName
                    #     }
                    #     conversation = @{
                    #         id = $conversationId
                    #         name = ''
                    #     }
                    #     recipient = @{
                    #         id = $fromId
                    #         name = $fromName
                    #     }
                    #     replyToId = $activityId
                    #     attachments = @(
                    #         @{
                    #             contentType = 'application/vnd.microsoft.teams.card.file.consent'
                    #             name = $fileToUpload.Name
                    #             content = @{
                    #                 description = $fileToUpload.Description
                    #                 sizeInBytes = $fileToUpload.Size
                    #                 acceptContext = @{
                    #                     consentId = $fileToUpload.ConsentId
                    #                 }
                    #                 declineContext = @{
                    #                     consentId = $fileToUpload.ConsentId
                    #                 }
                    #             }
                    #         }
                    #     )
                    # } | ConvertTo-Json -Depth 15

                    # $fileConsentRequest | Out-File -FilePath "$script:moduleBase/file-requests.json" -Append
                    # $this.LogDebug("Sending file upload request [$($fileToUpload.ConsentId)] to Teams conversation [$conversationId]")
                    # try {
                    #     $responseParams = @{
                    #         Uri         = $responseUrl
                    #         Method      = 'Post'
                    #         Body        = $fileConsentRequest
                    #         ContentType = 'application/json'
                    #         Headers     = $headers
                    #     }
                    #     $teamsResponse = Invoke-RestMethod @responseParams

                    #     $this.FileUploadTracker.Add($fileToUpload.ConsentId, $fileToUpload)

                    # } catch {
                    #     $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                    # }

                    # $contentType = 'application/octet-stream'
                    # if (($null -eq $global:IsWindows) -or $global:IsWindows) {

                    # } else {
                    #     if (Get-Command -Name file -CommandType Application) {
                    #         $contentType =  & file --mime-type -b $customResponse.Path
                    #     }
                    # }

                    # $uploadParams = @{
                    #     type           = $contentType
                    #     name           = $customResponse.Title
                    # }

                    # if ((Test-Path $customResponse.Path -ErrorAction SilentlyContinue)) {
                    #     $bytes = [System.Text.Encoding]::UTF8.GetBytes($customResponse.Path)
                    #     $uploadParams.originalBase64  = [System.Convert]::ToBase64String($bytes)
                    #     $uploadParams.thumbnailBase64 = [System.Convert]::ToBase64String($bytes)
                    #     $this.LogDebug("Uploading [$($customResponse.Path)] to Teams conversation [$conversationId]")
                    #     $payLoad = $uploadParams | ConvertTo-Json
                    #     $this.LogDebug('JSON payload', $payLoad)
                    #     $attachmentUrl = "$($baseUrl)v3/conversations/$conversationId/attachments"

                    #     $responseParams = @{
                    #         Uri         = $attachmentUrl
                    #         Method      = 'Post'
                    #         Body        = $payLoad
                    #         ContentType = 'application/json'
                    #         Headers     = $headers
                    #     }
                    #     $teamsResponse = Invoke-RestMethod @responseParams
                    # }

                    break
                }
            }
        }

        # Normal responses
        if ($Response.Text.Count -gt 0) {
            $this.LogDebug("Sending response back to Teams channel [$($Response.To)]")
            $this.SendTeamsMessaage($Response)
        }
    }

    # Add a reaction to an existing chat message
    # Currently only supports sending a 'typing' indicator to DMConverations
    [void]AddReaction([Message]$Message, [ReactionType]$Type, [string]$Reaction) {

        $baseUrl = $Message.RawMessage.serviceUrl
        $fromId = $Message.rawmessage.from.id
        $fromName = $Message.RawMessage.from.name
        $recipientId = $Message.RawMessage.recipient.id
        $recipientName = $Message.RawMessage.recipient.name
        $conversationId = $Message.RawMessage.conversation.id
        $activityId = $Message.RawMessage.id
        $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/$activityId"
        $channelId = $Message.RawMessage.channelData.teamsChannelId

        $headers = @{
            Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)"
        }

        # Currently only DMs work, but the documentation doesn't indicate that
        if ($Message.isDM) {
            $conversationId = $this._CreateDMConversation($fromId)
            $activityId = $conversationId
            $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/"
        }

        if ($Type -eq [ReactionType]::Processing) {
            $cardBody = @{
                type         = 'typing'
                from         = @{
                    id   = $fromId
                    name = $fromName
                }
                conversation = @{
                    id   = $conversationId
                    name = ''
                }
                recipient    = @{
                    id   = $recipientId
                    name = $recipientName
                }
                replyToId    = $activityId
                channelId    = $channelId
            }

            $body = $cardBody | ConvertTo-Json -Depth 15
            Write-Verbose $body

            $this.LogDebug("Sending typing indicator to Teams conversation [$conversationId]", $body)

            try {
                $responseParams = @{
                    Uri         = $responseUrl
                    Method      = 'Post'
                    Body        = $body
                    ContentType = 'application/json;charset=utf-8'
                    Headers     = $headers
                }
                Invoke-RestMethod @responseParams
            } catch {
                $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
            }
        }
    }

    # Remove a reaction from an existing chat message
    [void]RemoveReaction([Message]$Message, [ReactionType]$Type, [string]$Reaction) {
        # NOT IMPLEMENTED YET
    }

    # Directory with the Teams cache files (offline member list, learned users)
    hidden [string]_TeamsDir() {
        $dir = Join-Path -Path $env:USERPROFILE -ChildPath '.poshbot.teams'
        if (-not (Test-Path -Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force > $null
        }
        return $dir
    }

    # Write a clixml file atomically (temp file + rename) so a crash never leaves a half-written cache
    hidden [void]_SaveClixml([object]$Data, [string]$Path) {
        $tmp = "$Path.tmp"
        $Data | Export-Clixml -Path $tmp -Force
        Move-Item -Path $tmp -Destination $Path -Force
    }

    # Build a TeamsPerson from a member record (Bot Framework member / learned user)
    hidden [TeamsPerson]_NewPerson([object]$Member) {
        $user = [TeamsPerson]::new()
        $user.Id = $Member.id
        $user.FirstName = $Member.givenName
        $user.LastName = $Member.surname
        $user.UserPrincipalName = $Member.userPrincipalName
        $user.Email = $Member.email
        $user.FullName = ("$($Member.givenName) $($Member.surname)").Trim()
        if ([string]::IsNullOrEmpty($user.FullName)) { $user.FullName = $Member.name }
        if (-not [string]::IsNullOrEmpty($Member.userPrincipalName)) {
            $user.NickName = $Member.userPrincipalName
        } elseif (-not [string]::IsNullOrEmpty($Member.email)) {
            $user.NickName = $Member.email
        } else {
            $user.NickName = $Member.name
        }
        return $user
    }

    # Read all team members from Teams. Returns $null when anything fails, so a partial list is never used or cached
    hidden [object[]]_FetchAllMembers() {
        $uri = "$($this.ServiceUrl)v3/conversations/$($this.TeamId)/pagedmembers?pageSize=500"
        $headers = @{ Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)" }
        $all = [Collections.Generic.List[object]]::new()
        while ($true) {
            $page = $null
            $throttled = 0
            while ($null -eq $page) {
                try {
                    $page = Invoke-RestMethod -Headers $headers -Uri $uri -UseBasicParsing -Method 'GET' -ContentType 'application/json' -ErrorAction Stop
                } catch {
                    $code = $null
                    try { $code = $_.Exception.Response.StatusCode.value__ } catch { $code = $null }
                    if ($code -eq 429 -and $throttled -lt 10) {
                        $throttled++
                        $this.LogInfo([LogSeverity]::Warning, "Got throttled by Microsoft ($throttled). Sleeping for 45 seconds...")
                        Start-Sleep -Seconds 45
                        continue
                    }
                    $this.LogInfo([LogSeverity]::Error, 'Error getting the list of Teams users. The list will NOT be cached', @{ StatusCode = $code; Error = $_.Exception.Message; LoadedSoFar = $all.Count })
                    return $null
                }
            }
            if ($page.members) { $all.AddRange([object[]]@($page.members)) }
            if ($page.continuationToken) {
                $uri = "$($this.ServiceUrl)v3/conversations/$($this.TeamId)/pagedmembers?pageSize=500&continuationToken=$([uri]::EscapeDataString($page.continuationToken))"
            } else {
                break
            }
        }
        if ($all.Count -eq 0) {
            $this.LogInfo([LogSeverity]::Error, 'Teams returned an empty list of users. The list will NOT be cached')
            return $null
        }
        return $all.ToArray()
    }

    hidden [void]_LoadLearnedUsers() {
        $file = Join-Path -Path $this._TeamsDir() -ChildPath 'LearnedTeamsUsers.xml'
        $this._LearnedUsersLoaded = $true
        if (Test-Path -Path $file) {
            try {
                foreach ($rec in @(Import-Clixml -Path $file)) {
                    if ($rec.id -and -not $this._LearnedUsers.ContainsKey($rec.id)) {
                        $this._LearnedUsers[$rec.id] = $rec
                    }
                }
                $this.LogInfo("[Teams] Learned users loaded: $($this._LearnedUsers.Count)")
            } catch {
                $this.LogInfo([LogSeverity]::Warning, "Unable to read [$file]", [ExceptionFormatter]::Summarize($_))
            }
        }
    }

    hidden [void]_SaveLearnedUsers() {
        $file = Join-Path -Path $this._TeamsDir() -ChildPath 'LearnedTeamsUsers.xml'
        try {
            $this._SaveClixml(@($this._LearnedUsers.Values), $file)
        } catch {
            $this.LogInfo([LogSeverity]::Warning, "Unable to save [$file]", [ExceptionFormatter]::Summarize($_))
        }
    }

    # Make sure the sender of a message is a known user. If not, get their profile from the conversation
    # (GET v3/conversations/{id}/members/{userId}) or, failing that, from the message itself, and remember them
    hidden [void]_EnsureUser([pscustomobject]$Activity) {
        $from = $Activity.from
        if (-not $from -or [string]::IsNullOrEmpty($from.id)) { return }
        if (-not $this._LearnedUsersLoaded) { $this._LoadLearnedUsers() }

        $known = $this.Users[$from.id]
        if ($known) {
            # Learned earlier without an e-mail/UPN? Retry the profile lookup, but not more often than every 10 minutes
            $rec = $this._LearnedUsers[$from.id]
            $hasContact = (-not [string]::IsNullOrEmpty($known.Email)) -or (-not [string]::IsNullOrEmpty($known.UserPrincipalName))
            if ($hasContact -or -not $rec -or (([datetime]::UtcNow - [datetime]$rec.lastTry).TotalMinutes -lt 10)) { return }
        }

        $info = $null
        $source = 'message'
        try {
            $baseUrl = $Activity.serviceUrl
            if ([string]::IsNullOrEmpty($baseUrl)) { $baseUrl = $this.ServiceUrl }
            $url = "$($baseUrl)v3/conversations/$([uri]::EscapeDataString($Activity.conversation.id))/members/$([uri]::EscapeDataString($from.id))"
            $headers = @{ Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)" }
            $info = Invoke-RestMethod -Uri $url -Headers $headers -Method 'GET' -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
            $source = 'member-api'
        } catch {
            $this.LogInfo([LogSeverity]::Warning, "Unable to get the profile of user [$($from.id)] from Teams. Using data from the message", @{ Error = $_.Exception.Message })
        }

        $learnedAt = [datetime]::UtcNow
        if ($this._LearnedUsers[$from.id]) { $learnedAt = $this._LearnedUsers[$from.id].learnedAt }
        $name = $from.name
        if ($info.name) { $name = $info.name }
        $aad = $from.aadObjectId
        if ($info.aadObjectId) { $aad = $info.aadObjectId }

        $rec = [pscustomobject]@{
            id                = $from.id
            name              = $name
            givenName         = $info.givenName
            surname           = $info.surname
            email             = $info.email
            userPrincipalName = $info.userPrincipalName
            aadObjectId       = $aad
            tenantId          = $info.tenantId
            source            = $source
            learnedAt         = $learnedAt
            lastTry           = [datetime]::UtcNow
        }
        $this._LearnedUsers[$from.id] = $rec
        $this.Users[$from.id] = $this._NewPerson($rec)
        $this._SaveLearnedUsers()
        $this.LogInfo("[Teams] Learned user [$($rec.id)] ($($rec.name)) from [$source]")
    }

    # Reload users after a cache miss, but not more often than UserReloadMinIntervalSeconds
    hidden [bool]_ReloadUsersThrottled() {
        $age = ([datetime]::UtcNow - $this._LastUserLoad).TotalSeconds
        if ($age -lt $this.UserReloadMinIntervalSeconds) {
            $this.LogDebug("Users were refreshed [$([int]$age)] s ago. Not reloading again yet")
            return $false
        }
        $this.LoadUsers()
        return $true
    }

    # Populate the list of users the team.
    # Source: OfflineTeamsUsers.xml when it is younger than 7 days, otherwise Teams (paged). Plus users learned from messages.
    [void]LoadUsers() {
        if ([string]::IsNullOrEmpty($this.ServiceUrl)) { return }

        $this._LastUserLoad = [datetime]::UtcNow
        $this.LogInfo('Getting Teams users')

        $offlineFile = Join-Path -Path $this._TeamsDir() -ChildPath 'OfflineTeamsUsers.xml'
        $members = $null
        $fromTeams = $false

        $cacheOk = $false
        if (Test-Path -Path $offlineFile) {
            $fi = Get-Item -Path $offlineFile
            $cacheOk = ($fi.Length -gt 1024) -and ($fi.LastWriteTime -gt (Get-Date).AddDays(-7))
        }

        if ($cacheOk) {
            $this.LogInfo('[Teams] Getting Users (XML) - OFFLINE')
            try {
                $members = @(Import-Clixml -Path $offlineFile)
            } catch {
                $this.LogInfo([LogSeverity]::Warning, "Unable to read [$offlineFile]. Falling back to Teams", [ExceptionFormatter]::Summarize($_))
                $members = $null
            }
        }

        if ($null -eq $members) {
            $this.LogInfo('[Teams] Getting Users (Teams) - Online')
            $members = $this._FetchAllMembers()
            if ($null -ne $members) {
                $fromTeams = $true
                try {
                    $this._SaveClixml($members, $offlineFile)
                } catch {
                    $this.LogInfo([LogSeverity]::Warning, "Unable to write [$offlineFile]", [ExceptionFormatter]::Summarize($_))
                }
            } elseif (Test-Path -Path $offlineFile) {
                # Online refresh failed: an old list is better than none
                $this.LogInfo([LogSeverity]::Warning, '[Teams] Using the OLD offline list of users')
                try { $members = @(Import-Clixml -Path $offlineFile) } catch { $members = $null }
            }
        }

        if ($null -eq $members) {
            $this.LogInfo([LogSeverity]::Error, '[Teams] No list of users available. Keeping the users we already know')
            return
        }

        $this.LogInfo('[Teams] Users: ' + @($members).Count)

        # Add new users (a freshly downloaded list also refreshes the existing ones)
        $memberIds = [Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) {
            if ([string]::IsNullOrEmpty($m.id)) { continue }
            [void]$memberIds.Add([string]$m.id)
            if ($fromTeams -or -not $this.Users.ContainsKey($m.id)) {
                $this.Users[$m.id] = $this._NewPerson($m)
            }
        }

        # Users learned from messages: keep them, add the missing ones, forget those that are now in the member list
        if (-not $this._LearnedUsersLoaded) { $this._LoadLearnedUsers() }
        $changed = $false
        foreach ($id in @($this._LearnedUsers.Keys)) {
            if ($memberIds.Contains($id)) {
                $this._LearnedUsers.Remove($id)
                $changed = $true
            } elseif (-not $this.Users.ContainsKey($id)) {
                $this.Users[$id] = $this._NewPerson($this._LearnedUsers[$id])
            }
        }
        if ($changed) { $this._SaveLearnedUsers() }

        # Remove users that are neither in the member list nor learned (HashSet lookup, iterate over a copy)
        foreach ($key in @($this.Users.Keys)) {
            if (-not $memberIds.Contains($key) -and -not $this._LearnedUsers.ContainsKey($key)) {
                $this.LogDebug("Removing outdated user [$key]")
                $this.Users.Remove($key)
            }
        }
        $this.LogDebug('Finished getting Teams users')
    }

    # Populate the list of channels in the team
    [void]LoadRooms() {
        $this._LastRoomLoad = [datetime]::UtcNow
        $this.LogDebug('Getting Teams channels')

        $uri = "$($this.ServiceUrl)v3/teams/$($this.TeamId)/conversations"
        $headers = @{
            Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)"
        }
        try {
            $channels = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
        } catch {
            $this.LogInfo([LogSeverity]::Warning, 'Unable to get the list of Teams channels', [ExceptionFormatter]::Summarize($_))
            return
        }

        if ($channels.conversations) {
            $ids = [Collections.Generic.HashSet[string]]::new()
            foreach ($c in $channels.conversations) {
                $channel = [TeamsChannel]::new()
                $channel.Id = $c.id
                $channel.Name = $c.name
                [void]$ids.Add([string]$c.id)
                $this.Rooms[$c.id] = $channel
            }

            foreach ($key in @($this.Rooms.Keys)) {
                if (-not $ids.Contains($key)) {
                    $this.LogDebug("Removing outdated channel [$key]")
                    $this.Rooms.Remove($key)
                }
            }
        }
    }

    [bool]MsgFromBot([string]$From) {
        return $false
    }

    # Get a user by their Id
    [TeamsPerson]GetUser([string]$UserId) {
        $user = $this.Users[$UserId]
        if (-not $user) {
            $this.LogDebug([LogSeverity]::Warning, "User [$UserId] not found. Refreshing users")
            [void]$this._ReloadUsersThrottled()
            $user = $this.Users[$UserId]
        }

        if ($user) {
            $this.LogDebug("Resolved user [$UserId]", $user)
        } else {
            $this.LogDebug([LogSeverity]::Warning, "Could not resolve user [$UserId]")
        }
        return $user
    }

    # Get a user Id by their name
    [string]UsernameToUserId([string]$Username) {
        $Username = $Username.TrimStart('@')
        $user = $this.Users.Values | Where-Object { $_.Nickname -eq $Username }
        $id = $null
        if ($user) {
            $id = $user.Id
        } else {
            # User each doesn't exist or is not in the local cache
            # Refresh it and try again
            $this.LogDebug([LogSeverity]::Warning, "User [$Username] not found. Refreshing users")
            [void]$this._ReloadUsersThrottled()
            $user = $this.Users.Values | Where-Object { $_.Nickname -eq $Username }
            if (-not $user) {
                $id = $null
            } else {
                $id = $user.Id
            }
        }
        if ($id) {
            $this.LogDebug("Resolved [$Username] to [$id]")
        } else {
            $this.LogDebug([LogSeverity]::Warning, "Could not resolve user [$Username]")
        }
        return $id
    }

    # Get a user name by their Id
    [string]UserIdToUsername([string]$UserId) {
        $name = $null
        if ($this.Users.ContainsKey($UserId)) {
            $name = $this.Users[$UserId].Nickname
        } else {
            $this.LogDebug([LogSeverity]::Warning, "User [$UserId] not found. Refreshing users")
            [void]$this._ReloadUsersThrottled()
            $name = $this.Users[$UserId].Nickname
        }
        if ($name) {
            $this.LogDebug("Resolved [$UserId] to [$name]")
        } else {
            $this.LogDebug([LogSeverity]::Warning, "Could not resolve user [$UserId]")
        }
        return $name
    }

    # Get the channel name by Id. IDs that are not team channels (the bot's own id, personal chats) are
    # remembered for UnknownRoomTtlMinutes so they do not trigger a Teams call on every message
    [string]ChannelIdToName([string]$ChannelId) {
        $name = $null
        if ($this.Rooms.ContainsKey($ChannelId)) {
            $name = $this.Rooms[$ChannelId].Name
        } else {
            $unknownSince = $this._UnknownRooms[$ChannelId]
            $isKnownUnknown = $unknownSince -and (([datetime]::UtcNow - [datetime]$unknownSince).TotalMinutes -lt $this.UnknownRoomTtlMinutes)
            if (-not $isKnownUnknown) {
                if (([datetime]::UtcNow - $this._LastRoomLoad).TotalSeconds -ge $this.RoomReloadMinIntervalSeconds) {
                    $this.LogDebug([LogSeverity]::Warning, "Channel [$ChannelId] not found. Refreshing channels")
                    $this.LoadRooms()
                    if ($this.Rooms.ContainsKey($ChannelId)) {
                        $name = $this.Rooms[$ChannelId].Name
                    } else {
                        $this._UnknownRooms[$ChannelId] = [datetime]::UtcNow
                    }
                }
            }
        }
        if ($name) {
            $this.LogDebug("Resolved [$ChannelId] to [$name]")
        } else {
            $this.LogDebug([LogSeverity]::Warning, "Could not resolve channel [$ChannelId]")
        }
        return $name
    }

    # Resolve From name
    [string]ResolveFromName([Message]$Message) {
        $fromName = $null
        if ($Message.From) {
            $fromName = $this.UserIdToUsername($Message.From)
        }
        return $fromName
    }

    # Resolve To name
    [string]ResolveToName([Message]$Message) {
        $toName = $null
        if ($Message.To) {
            $toName = $this.ChannelIdToName($Message.To)
        }
        return $toName
    }

    # Get all user info by their ID
    [hashtable]GetUserInfo([string]$UserId) {
        $user = $null
        if ($this.Users.ContainsKey($UserId)) {
            $user = $this.Users[$UserId]
        } else {
            $this.LogDebug([LogSeverity]::Warning, "User [$UserId] not found. Refreshing users")
            [void]$this._ReloadUsersThrottled()
            $user = $this.Users[$UserId]
        }

        if ($user) {
            $this.LogDebug("Resolved [$UserId] to [$($user.Nickname)]")
            return $user.ToHash()
        } else {
            $this.LogDebug([LogSeverity]::Warning, "Could not resolve channel [$UserId]")
            return $null
        }
    }

    hidden [void]DelayedInit([pscustomobject]$Message) {
        if (([string]::IsNullOrEmpty($this.ServiceUrl)) -or ($this.ServiceUrl -ne $Message.serviceUrl)) {
            $this.ServiceUrl = $Message.serviceUrl
            $this.LoadUsers()
            $this.LoadRooms()
        }

        if ([string]::IsNullOrEmpty($this.BotId)) {
            if ($Message.recipient) {
                $this.BotId = $Message.recipient.Id
                $this.BotName = $Message.recipient.name
            }
        }

        if ([string]::IsNullOrEmpty($this.TenantId)) {
            if ($Message.channelData.tenant.id) {
                $this.TenantId = $Message.channelData.tenant.id
            }
        }

        $this.Initialized = $true
    }

    hidden [void]SendTeamsMessaage([Response]$Response) {
        $baseUrl = $Response.OriginalMessage.RawMessage.serviceUrl
        $conversationId = $Response.OriginalMessage.RawMessage.conversation.id
        $activityId = $Response.OriginalMessage.RawMessage.id
        $responseUrl = "$($baseUrl)v3/conversations/$conversationId/activities/$activityId"
        $headers = @{
            Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)"
        }

        if ($Response.Text.Count -gt 0) {
            foreach ($text in $Response.Text) {
                $jsonResponse = @{
                    type         = 'message'
                    from         = @{
                        id   = $Response.OriginalMessage.RawMessage.recipient.id
                        name = $Response.OriginalMessage.RawMessage.recipient.name
                    }
                    conversation = @{
                        id   = $Response.OriginalMessage.RawMessage.conversation.id
                        name = ''
                    }
                    recipient    = @{
                        id   = $Response.OriginalMessage.RawMessage.from.id
                        name = $Response.OriginalMessage.RawMessage.from.name
                    }
                    text         = $text
                    replyToId    = $activityId
                } | ConvertTo-Json

                # $jsonResponse | Out-File -FilePath "$script:moduleBase/responses.json" -Append
                $this.LogDebug("Sending response back to Teams conversation [$conversationId]")
                try {
                    $responseParams = @{
                        Uri         = $responseUrl
                        Method      = 'Post'
                        Body        = $jsonResponse
                        ContentType = 'application/json;charset=utf-8'
                        Headers     = $headers
                    }
                    Invoke-RestMethod @responseParams
                } catch {
                    $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                }
            }
        }
    }

    # Create a new DM conversation and return the converation ID
    # If there is an existing conversation, return that ID
    hidden [string]_CreateDMConversation([string]$UserId) {
        if ($this.DMConverations.ContainsKey($userId)) {
            return $this.DMConverations[$UserId]
        } else {
            $newConversationUrl = "$($this.ServiceUrl)v3/conversations"
            $headers = @{
                Authorization = "Bearer $($this.Connection._AccessTokenInfo.access_token)"
            }

            $conversationParams = @{
                bot         = @{
                    id   = $this.BotId
                    name = $this.BotName
                }
                members     = @(
                    @{
                        id = $UserId
                    }
                )
                channelData = @{
                    tenant = @{
                        id = $this.TenantId
                    }
                }
            }

            $body = $conversationParams | ConvertTo-Json
            #$body | Out-File -FilePath "$script:moduleBase/create-dm.json" -Append
            $params = @{
                Uri         = $newConversationUrl
                Method      = 'Post'
                Body        = $body
                ContentType = 'application/json;charset=utf-8'
                Headers     = $headers
            }
            $conversation = Invoke-RestMethod @params
            if ($conversation) {
                $this.LogDebug("Created DM conversation [$($conversation.id)] with user [$UserId]")
                return $conversation.id
            } else {
                $this.LogInfo([LogSeverity]::Error, "$($_.Exception.Message)", [ExceptionFormatter]::Summarize($_))
                return $null
            }
        }
    }

    hidden [hashtable]_GetCardStub() {
        return @{
            type         = 'message'
            from         = @{
                id   = $null
                name = $null
            }
            conversation = @{
                id = $null
                #name = ''
            }
            recipient    = @{
                id   = $null
                name = $null
            }
            attachments  = @(
                @{
                    contentType = 'application/vnd.microsoft.card.adaptive'
                    content     = @{
                        type         = 'AdaptiveCard'
                        version      = '1.0'
                        fallbackText = $null
                        body         = @(
                            @{
                                type    = 'Container'
                                spacing = 'none'
                                items   = @(
                                    # # Title & Thumbnail row
                                    @{
                                        type    = 'ColumnSet'
                                        spacing = 'none'
                                        columns = @()
                                    }
                                    # Text & image row
                                    @{
                                        type    = 'ColumnSet'
                                        spacing = 'none'
                                        columns = @()
                                    }
                                    # Facts row
                                    @{
                                        type  = 'FactSet'
                                        facts = @()
                                    }
                                )
                            }
                        )
                    }
                }
            )
            replyToId    = $null
        }
    }

    hidden [string]_RepairText([string]$Text) {
        if (-not [string]::IsNullOrEmpty($Text)) {
            $fixed = $Text.Replace('"', '\"').Replace('\', '\\').Replace("`n", '\n\n').Replace("`r", '').Replace("`t", '\t')
            $fixed = [System.Text.RegularExpressions.Regex]::Unescape($Text)
        } else {
            $fixed = ' '
        }

        return $fixed
    }

}
