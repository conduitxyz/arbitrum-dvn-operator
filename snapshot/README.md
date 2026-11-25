# snapshot/

Put the follower's starting snapshot here, then run `docker compose up -d`.

On an empty follower volume, the `nitro-follower-restore` container extracts
`latest.tar` from this folder (or the parts `snapshot_part_*.tar.part` of a split
snapshot) into the volume, and the follower catches up from the snapshot's block
instead of re-executing the chain from genesis. For the DVN's full-node snapshot
(a requester-pays bucket: you need a Google Cloud project with billing):

```bash
gcloud storage cp gs://conduit-networks-snapshots/<chain>/full/latest.tar ./snapshot/ --billing-project=<your-project>
docker compose up -d
```

- Run `docker compose up -d` after the download finishes. While `gcloud` is
  downloading, the file is `latest.tar_.gstmp`, and the restore stops with a
  message rather than start the follower from genesis.
- The volume needs the snapshot's size free, on top of the file itself.
- Once the node is running, delete the file: it isn't used again.

See "Start from a snapshot" in the bundle's README.
