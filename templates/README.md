# templates/

Starting points for scaffolding new apps. None yet.

Every template that supports background jobs implements the language-neutral contract in
[`platform/jobs/CONTRACT.md`](../platform/jobs/CONTRACT.md): the `enqueue(job, payload)` helper and the
`POST /_jobs/<name>` handler, and passes its conformance checklist.
