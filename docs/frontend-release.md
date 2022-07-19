# Frontend Release

The frontend code is released into a publicly accessible Azure Storage File Share where all deployments and external entities have access to the released results.

The public Azure Storage is named `wildmepublic`. This public space has the potential to be used for more than just frontend releases. Frontend releases are available in the File Share named `frontend-releases`.

## Codex Frontend Releases

At this time, the built results of [codex-frontend](https://github.com/WildMeOrg/codex-frontend) are manually uploaded into the `frontend-releases` within a directory named `codex-frontend-X.Y.Z`.

Symbolic links in `frontend-releases` named `codex-frontend-latest` and `codex-frontend-stable` are made to point at the latest release.

At this time, switching the symbolic link for `codex-frontend-latest` will switch over all deployments of the frontend in the cluster.
