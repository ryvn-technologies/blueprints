# Private Service Connect consumer (GCP)

Connects a VPC to a [Private Service Connect](https://docs.cloud.google.com/vpc/docs/about-accessing-vpc-hosted-services-endpoints) service attachment in the same region. It creates:

- a Private Service Connect endpoint with an internal IP address from a subnet you choose,
- firewall rules that only let the VPC reach the endpoint on TCP 80 and 443,
- a private DNS zone that points `*.<publisher_domain>` at the endpoint.

It outputs the endpoint's forwarding rule ID and the connection state, which is `ACCEPTED` once the publisher accepts this project and `PENDING` until then.

The `private-service-publisher` module is the publisher side.

## On Ryvn

The Private Service Consumer blueprint installs this module with the `publisherId` and `publisherDomain` outputs of a Private Service Publisher in the same region, and reports the connection state as `linkState`. Names under `publisherDomain` then resolve to the endpoint, so installations call a service at the same URL it has in the publisher's environment, like `https://<name>.<publisherDomain>`. The publisher's gateway serves a publicly trusted certificate for those names.

The publisher has to allow this environment's project first, and only services with an internal [Route](https://ryvn.ai/docs/networking/routes) in the publisher's environment are reachable.
