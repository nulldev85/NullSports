# Library reliability and server integrations

## Library review

Existing Library features and source identities remain in place. Refreshes now
distinguish a failed shelf from an intentionally empty shelf. A failed request
retains its last successful contents and marks the server load retryable. Shelf
requests are limited to four per server and retain the saved shelf ordering.

Concurrent detail consumers share one request and a bounded ten-minute cache.
Metadata parent resolution uses that same path. Removing a server cancels its
detail requests and invalidates any combined inventory; late results cannot
reintroduce that account's titles. Concurrent inventory consumers share one scan.

Four SDK regressions exercise the actual MediaLibrary with a URLSession fixture:
coalesced detail consumers, removal during details, failed versus empty shelf
refreshes, and inventory coalescing/removal. They run on both targets. SDK execution
is pending GitHub CI; Windows has no Apple SDK.

## API references

Implementations are being developed against these official contracts:

- Seerr: https://docs.seerr.dev/api/seerr-api/
  and `seerr-api.yml` at `seerr-team/seerr` revision
  `c57dca90f567eb659add041307555192cee23860`.
- Silo: https://siloserver.org/docs/api and `contracts/api/v2/openapi.json`
  at `Silo-Server/silo-server` revision
  `6de6d5e5e285a9b423e95a1122cb39e5bb9ca93b`.

Silo uses native v2, string identifiers, profile authorization, cursor pagination,
and protocol-v3 playback decisions. Seerr uses v1 with server permissions and
request quotas. Neither integration has been completed or validated yet.
