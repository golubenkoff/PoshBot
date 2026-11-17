@{
    ExcludeRules = @(
        'PSUseBOMForUnicodeEncodedFile'
        # Information-level rule; crashes (NullReferenceException in Helper.GetExportedFunction) when
        # PSScriptAnalyzer 1.21-1.23 runs inside the psake build on the compiled PoshBot.psm1
        'PSProvideCommentHelp'
    )
}
