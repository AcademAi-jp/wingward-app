# Judging voice recovery

## Runtime limits and their scope

The server owns the initial configuration, admission, expiry and hangup alarm.
The sideband checks reported session settings, response output limits/modalities,
usage, counts, and conversation item types. Usage arrives after generation; the
cumulative token threshold is an observed-usage stop threshold, not a provider
guarantee that a single response can never overshoot it. Sideband detection and
hangup also have transport latency.

OpenAI's Response event schema does not expose per-response instructions or tool
definitions. Do not claim that these overrides are fully prevented by inspecting
`response.created`. The public client-event API supports such overrides; a strict
preventive boundary would require control over the client's event transport or a
provider-enforced immutable policy. This remains a limitation to resolve before
claiming that all client configuration changes are blocked.

References: [official Response schema](https://github.com/openai/openai-node/blob/master/src/resources/realtime/realtime.ts)
and [client events](https://platform.openai.com/docs/api-reference/realtime-client-events).

Use this procedure when a judging voice request fails or remains blocked. A
successful sign-in, HTTP 201, or WebRTC connection is not evidence that the user
heard an AI response. Record that result separately from connection readiness.

## Identify the state before retrying

Inspect only the affected account and context through an authorized operator
channel. Keep credentials, provider call IDs, transcripts, and private account
identifiers out of review material and public logs. The controller's private
status response reports `status`, `providerCreated`, `settled`, and a fixed
`closeReason`; it does not expose the call ID or conversation content.

The old readiness GET endpoint is limited to its original diagnostic window and
owner. It is not a general status endpoint. An expired diagnostic window must
not be reopened by changing its issue time or replaying its fixed context.

| State | Recovery |
| --- | --- |
| No provider request was started, or the provider explicitly rejected creation | The normal path settles the exact account and reservation. Check that settlement succeeded before expecting another context to work. |
| A provider call ID is known | Use the owner's stop path. The controller acknowledges provider hangup before settling and retries failed cleanup through its durable alarm. |
| Creation timed out, returned an ambiguous result, or an old lease lacks creation evidence | Keep admission blocked. Obtain authoritative provider evidence that no call exists or that the affected call has ended. Elapsed lease time alone is insufficient. There is no automatic reconciliation tool for this state. |
| Provider cleanup is confirmed but database settlement failed | A controller-owned closed lease retries settlement. A route-only no-attempt failure has no durable retry; an authorized operator must reconcile that exact reservation after proving no provider request started. |

Do not clear every unsettled lease, delete reservation history, reset quotas, or
substitute another actor. Settlement closes runtime admission only; it does not
restore a consumed request or permit the same interview context to run again.
Any manual reconciliation must retain evidence of the exact affected reservation
and provider outcome in private operational records and independently verify the
result. If evidence is missing, keep the account blocked and investigate.

## Confirm recovery

Verify that the provider is closed (or was never started), the exact lease is
settled, and unrelated reservations remain unchanged. A fresh diagnostic needs
its own context, explicitly bounded time window and duration, and an available
stop path. Preserve account expiry and all count, token, and duration limits.

For an actual app check, the person completes their own age gate and onboarding,
speaks into the microphone, hears a response, and ends the conversation through
the app. Confirm server cleanup afterward. Synthetic database fixtures and local
UI tests cannot substitute for this hosted audio check.
