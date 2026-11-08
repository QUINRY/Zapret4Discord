# Only reviewed TLS actions are accepted. Profiles cannot change packet scope.
function Import-DiscordProfiles([string]$Path) {
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.SchemaVersion -ne 1 -or @($catalog.Profiles).Count -eq 0) { throw 'Invalid profile catalog.' }
    $strategies = [ordered]@{}
    foreach ($profile in $catalog.Profiles) {
        if ($profile.Id -cnotmatch '^[a-z0-9][a-z0-9-]{1,60}$' -or $strategies.Contains([string]$profile.Id)) { throw 'Invalid or duplicate profile ID.' }
        if (@($profile.Arguments).Count -eq 0) { throw "Empty profile: $($profile.Id)" }
        foreach ($argument in $profile.Arguments) {
            if ($argument -cnotmatch '^--lua-desync=(fake|multisplit|multidisorder|fakedsplit|hostfakesplit)(:[A-Za-z0-9_.,=+/#-]+)*$') {
                throw "Profile attempts to change traffic scope or use an unreviewed action: $($profile.Id)"
            }
        }
        foreach ($initialization in @($profile.Init)) {
            if ($initialization -cne "fake_default_tls=tls_mod(fake_default_tls,'rnd')") { throw 'Unreviewed profile initialization.' }
        }
        $strategies.Add([string]$profile.Id, [string[]]@($profile.Arguments))
    }
    $Script:ProfileCatalog = $catalog
    $Script:Profiles = @($catalog.Profiles)
    $Script:Strategies = $strategies
}
