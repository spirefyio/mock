# mock

Zig mock used by Spirefy and open sourced for others to use.

`mock` is a Zig library for building working mocks of APIs at run time, in memory: the HTTP or
SOAP server, the message broker, and the identity provider that issues the tokens, all inside
the process that uses it. A test describes the API it needs and `mock` serves it, with no
containers and no outside services.

> **Status: early construction.** The first slice is being built in stages, and nothing is usable
> yet. This README sets out the scope we are building toward. It is not a list of things that
> work. An item counts as working only once it passes against independent software (see
> [How it is checked](#how-it-is-checked)).

## Why

Testing an API client, an SDK or a workflow runner against real infrastructure usually means
running a stack of containers: a web server, Kafka or RabbitMQ, an MQTT broker, and Keycloak or
another identity provider. `mock` is meant to replace that stack with one library that a test
starts, changes and stops by itself.

## What it mocks

| Protocol | `mock` is | Scope |
|---|---|---|
| HTTP | a server | HTTP/1.1, plain or over TLS |
| SOAP | a server | SOAP 1.1 and 1.2 over HTTP, with faults |
| WebSocket | a server | RFC 6455 |
| MQTT | a broker | 3.1.1 and 5.0: QoS 0, 1 and 2, retained messages, wills, sessions |
| AMQP | a broker | 0-9-1, as RabbitMQ's clients speak it: exchanges, queues, bindings, acknowledgements, reply-to |
| Kafka | a broker | what clients need: metadata, produce, fetch, offsets, consumer groups |
| GraphQL | a server | later |
| gRPC | a server | later |

HTTP comes first; WebSocket, the brokers and SOAP follow.

A mock answers from the API's description: its examples first, then values generated from its
schemas. Requests are validated against the description, and an invalid one gets an error
response.

## Identity

A mock can include an identity provider, in the same process, so APIs that need
authentication work end to end. It grows in steps.

First:

- API keys in a header, query parameter or cookie
- HTTP basic authentication
- Bearer tokens, including JSON Web Tokens signed with HS256, ES256 or EdDSA
- An OAuth 2.0 client-credentials token endpoint that issues them

Then, as our conformance tests need them:

- JSON Web Tokens signed with RS256
- OAuth 2.0: authorization code with PKCE, refresh tokens, device code, scopes, introspection
  and revocation
- OpenID Connect: discovery, JWKS, ID tokens and userinfo
- SASL for the brokers: PLAIN, SCRAM-SHA-256, SCRAM-SHA-512 and OAUTHBEARER
- Mutual TLS with client certificates
- SAML 2.0 single sign-on, and WS-Security for SOAP

Sign-in, when it arrives, is headless: an authorization request is approved as whichever test
user the test picks.

For negative tests the provider hands out bad credentials on purpose: expired, not yet valid,
for the wrong audience or issuer, wrongly signed, missing a scope, or revoked.

It is a test double, not a production identity provider. Its keys are made for each run and
exist only in memory. Never trust anything it signs outside a test.

## What a test gets

- A server or broker per protocol, each on a port the OS picks unless the test names one, so
  tests can run in parallel.
- The identity provider's endpoints, clients and test users.
- A record of every request, message and token the mock handled, so a test can check what a
  client actually sent.
- Faults on request: an error response, a delay, a dropped connection.
- Live changes: hand a running mock a new description and it serves that from then on.

## Principles

- **In memory, in one process.** Nothing to install or start besides the library.
- **Loopback by default.** Listeners bind to 127.0.0.1 unless told otherwise, and check the
  Host header so that a web page cannot reach them through DNS rebinding.
- **Bounded.** Queues, retained messages, sessions, records and tokens all have limits. Hitting
  one is an error you can see, never silent loss.
- **Model-neutral.** You describe an API with `mock`'s own Zig types. A tool that reads
  OpenAPI, AsyncAPI or WSDL maps its model onto them; Spirefy does this from its unified API
  model.
- **Deterministic.** Generated data comes from a seed, so a failing test fails the same way
  twice.
- **A stated subset.** `mock` implements what clients need in order to talk to it. Anything
  else is refused with an error that says what was refused, never answered wrongly.
- **Our own code, with credit.** Everything `mock` runs is in this repository, written in Zig
  0.16 with no dependencies beyond its standard library. Where we adapt code from another
  open-source project whose license allows it, the file keeps the original notice and says
  what changed, and the NOTICE file lists the source. Linux, macOS and Windows.

## Non-goals

- A production server, broker or identity provider.
- A load-testing tool.
- Reproducing every behaviour of every broker.

## How it is checked

A mock tested only with its authors' own clients proves little, because a misreading of a spec
on both sides agrees with itself. So each protocol is checked against independent software: the
same client scenarios run against a real server or broker and against `mock`, and the results
are compared. The references are Mosquitto for MQTT, RabbitMQ for AMQP and Apache Kafka for
Kafka, driven by their own clients and other established ones such as Eclipse Paho and
librdkafka. The identity provider is checked with established OAuth 2.0, OpenID Connect and
SAML tools on the relying-party side. All of this runs in CI; the library never depends on it.

## Using it

Nothing to use yet. `mock` will be a Zig package that you add to `build.zig.zon`.

## Credits

Code adapted from other open-source projects, and test vectors taken from them, are credited
in the files that use them and listed in the NOTICE file, with their sources and licenses.

## License

Apache License 2.0. See [LICENSE](LICENSE).
