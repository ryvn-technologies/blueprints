# Private endpoint (Azure)

Connects a VNet to an [Azure Private Link service](https://learn.microsoft.com/azure/private-link/private-endpoint-overview) in the same region or another one. It creates:

- a private endpoint in a subnet you choose, which sends a connection request to the service,
- a private DNS zone, linked to the VNet, that points `*.<private_dns_zone_name>` at the endpoint.

The endpoint doesn't filter ports, so it reaches every port that the service's load balancer forwards.

It outputs the endpoint ID and the connection state, which is `Approved` once the service approves the request and `Pending` until then.

The `private-link-service` module is the publisher side.

## On Ryvn

The Private Service Consumer blueprint installs this module with the `publisherId` and `publisherDomain` outputs of a Private Service Publisher, and reports the connection state as `linkState`. Names under `publisherDomain` then resolve to the endpoint, so installations call a service at the same URL it has in the publisher's environment, like `https://<name>.<publisherDomain>`. The publisher's gateway serves a publicly trusted certificate for those names and only forwards ports 80 and 443.

The publisher has to allow this environment's subscription first, and only services with an internal [Route](https://ryvn.ai/docs/networking/routes) in the publisher's environment are reachable.
