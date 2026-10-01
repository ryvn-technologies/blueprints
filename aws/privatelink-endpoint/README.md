# PrivateLink endpoint (AWS)

Connects a VPC to an [AWS PrivateLink](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html) endpoint service in the same region or another one. It creates:

- an interface endpoint in one of your subnets per availability zone that the service supports,
- a security group that only lets the VPC's own address ranges reach the endpoint, on TCP 80 and 443,
- a private hosted zone that points `*.<private_hosted_zone_name>` at the endpoint.

It outputs the endpoint ID and the endpoint state, which turns `available` once the service accepts the connection.

The `privatelink-endpoint-service` module is the publisher side.

## On Ryvn

The Private Service Consumer blueprint installs this module with the `publisherId` and `publisherDomain` outputs of a Private Service Publisher, and reports the endpoint state as `linkState`. Names under `publisherDomain` then resolve to the endpoint, so installations call a service at the same URL it has in the publisher's environment, like `https://<name>.<publisherDomain>`. The publisher's gateway serves a publicly trusted certificate for those names.

The publisher has to allow this environment's account first, and only services with an internal [Route](https://ryvn.ai/docs/networking/routes) in the publisher's environment are reachable.
