local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Version string formatting. Packaged builds get the git tag (already
-- "v"-prefixed); dev installs still carry the unsubstituted placeholder.
--------------------------------------------------------------------------

function ns.FormatVersion(raw)
  if not raw or raw == "" or raw:match("^@.-@$") then
    return "vdev"
  end
  return "v" .. (raw:match("^[vV](.+)$") or raw)
end
