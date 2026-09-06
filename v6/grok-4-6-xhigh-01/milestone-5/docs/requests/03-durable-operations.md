# Make partner operations durably idempotent

The partner gateway retries whenever it loses a response. `operation_id`, which has so far been a
reconciliation reference, must now prevent an operation from being applied twice.

The gateway will start a new operation-identifier namespace when this release is deployed, so no
idempotency records need to be reconstructed for operations originally submitted under earlier
releases. The guarantee begins with operations first received by this release.

## Retry behavior

- The first operation received for an `operation_id` is processed normally.
- A later operation with the same identifier and equivalent JSON payload returns the exact original
  result without reading or changing current domain state.
- JSON object key order is irrelevant. Array order and values remain significant.
- Rejected results are remembered just like applied results. A retry still receives the original
  rejection even if later operations would make it valid.
- Reusing an identifier with a different payload is rejected with `operation_id_conflict` and does
  not replace the original record.

Idempotency records and domain changes commit in the same database transaction. Concurrent retries
must have at-most-once effects. Under this request, a handled rejection leaves domain state
unchanged but commits its idempotency record; this replaces the earlier database-wide wording about
rejections. Other operations in the batch continue in order.

An unexpected exception rolls back the current operation and is not remembered as an idempotent
result. It aborts the HTTP request with `500`; the gateway may retry the batch. Batch continuation
applies to handled operation rejections, not unexpected server faults.

The behavior must survive application and database-process restarts.

The durable record is also Northstar's audit record of what the gateway submitted. For every
remembered operation, applied or rejected, retain its type and its complete submitted content
(object key order is not significant), and preserve the order in which durable records were first
committed.

Add `GET /api/v1/operations/:operation_id`. It returns the stored result as
`{"data": <result>}` or the usual `404` error with code `operation_not_found`. The endpoint exposes
only the stored result, not the retained submission or commit order.

The exact-result guarantee includes revisions and stale-revision details. An exact retry returns
the stored result verbatim, including the revision or `actual_revision` observed on the original
attempt, without consulting current group state. Retrying a stale operation under the same
`operation_id` with a corrected `expected_revision` is a different payload and therefore returns
`operation_id_conflict`.
