# tests/unit/test_graft_mediastep.bats — the pure argv-inspection halves of
# the media sync (design doc §6.4 step 1): never scp, ssh only when A/B is
# remote, and the push side never overwrites an existing file on B.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_media_pull_cmd routes A's uploads to a local staging dir via ssh when A is remote" {
  run graft_media_pull_cmd "user@host-a.example.com" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" == *"rsync"* ]] || false
  [[ "$output" == *"user@host-a.example.com"* ]] || false
  [[ "$output" != *"scp"* ]]
}

@test "graft_media_pull_cmd has no ssh hop when A is local" {
  run graft_media_pull_cmd "" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" != *"ssh"* ]] || [[ "$output" != *"@"* ]]
}

@test "graft_media_push_cmd never overwrites existing files on B" {
  run graft_media_push_cmd "user@host-b.example.com" "/run/media-staging/" "/site-b/wp-content/uploads/"
  [[ "$output" == *"--ignore-existing"* ]] || false
  [[ "$output" != *"scp"* ]]
}
