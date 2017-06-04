
class Scheduler {

    [hashtable]$Schedules = @{}

    [void]ScheduleMessage([ScheduledMessage]$ScheduledMessage) {
        if (-not $this.Schedules.ContainsKey($ScheduledMessage.Id)) {
            Write-Verbose -Message "[Scheduler:ScheduleMessage] Scheduled message [$($_.Value.Id)]"
            $ScheduledMessage.StartTimer()
            $this.Schedules.Add($ScheduledMessage.Id, $ScheduledMessage)
        } else {
            Write-Error "Id [$($ScheduledMessage.Id)] is already scheduled"
        }
    }

    [void]RemoveScheduledMessage([string]$Id) {
        if ($this.GetSchedule($Id)) {
            Write-Verbose -Message "[Scheduler:RemoveScheduledMessage] Scheduled message [$($_.Value.Id)] removed"
            $this.Schedules.Remove($id)
        }
    }

    [PSCustomObject[]]ListSchedules() {
        $result = $this.Schedules.GetEnumerator() |
            Select-Object -ExpandProperty Value |
            Sort-Object -Property TimeValue -Descending |
            Foreach-Object {
                [pscustomobject]@{
                    Id = $_.Id
                    Command = $_.Message.Text
                    Interval = "Every $($_.TimeValue) $($_.TimeInterval)"
                    TimesExecuted = $_.TimesExecuted
                    Enabled = $_.Enabled
                }
            }

        return $result
    }

    [Message[]]GetTriggeredMessages() {
        $messages = $this.Schedules.GetEnumerator() | Foreach-Object {
            if ($_.Value.HasElapsed()) {
                Write-Verbose -Message "[Scheduler:GetMessages] Timer reached on scheduled command [$($_.Value.Id)]"
                $_.Value.ResetTimer()
                $newMsg = $_.Value.Message.Clone()
                $newMsg.Time = Get-Date
                $newMsg
            }
        }
        return $messages
    }

    [ScheduledMessage]GetSchedule([string]$Id) {
        if ($msg = $this.Schedules[$id]) {
            return $msg
        } else {
            Write-Error -Message "Unknown schedule Id [$Id]"
            return $null
        }
    }
    [ScheduledMessage]EnableSchedule([string]$Id) {
        if ($msg = $this.GetSchedule($Id)) {
            Write-Verbose -Message "[Scheduler:EnableSchedule] Enabled scheduled command [$($_.Value.Id)] enabled"
            $msg.Enable()
            return $msg
        } else {
            return $null
        }
    }

    [ScheduledMessage]DisableSchedule([string]$Id) {
        if ($msg = $this.GetSchedule($Id)) {
            Write-Verbose -Message "[Scheduler:DisableSchedule] Disabled scheduled command [$($_.Value.Id)] enabled"
            $msg.Disable()
            return $msg
        } else {
            return $null
        }
    }
}
