local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Version string formatting
--
-- Pure so it's covered by the offline test suite. Two inputs need
-- normalizing before display:
--
--   - Packaged builds: the packager substitutes the version keyword with the
--     git tag verbatim, which already carries a "v" prefix (e.g. "v1.4.0").
--     Prepending another one here would double it.
--   - Dev installs: the substitution never runs, so the raw TOC metadata is
--     still the literal placeholder.
--------------------------------------------------------------------------

function ns.FormatVersion(raw)
  if not raw or raw == "" or raw:match("^@.-@$") then
    return "vdev"
  end
  return "v" .. (raw:match("^[vV](.+)$") or raw)
end
