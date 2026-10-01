# PrivateLink endpoint service (AWS)

Creates an [AWS PrivateLink endpoint service](https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-share-your-services.html) for an existing Network Load Balancer. VPCs in other accounts reach the load balancer through interface endpoints, and the traffic stays on the AWS network.

- Finds the load balancer by its tags. Exactly one load balancer in the region must match.
- Allows the IAM principals you list, or only this account if you list none.
- Can require you to accept each connection request (`acceptance_required`, on by default).
- Can take connections from other regions (`supported_regions`).
- Outputs the endpoint service name, which consumers connect to.

The `privatelink-endpoint` module is the consumer side.

## On Ryvn

The Private Service Publisher blueprint installs this module in the environment that runs your services. It publishes the load balancer in front of the environment's managed internal gateway, allows the accounts in `awsAllowedPrincipals` (this account if empty) and accepts their connections automatically. Its `publisherId` output is the endpoint service name.

Install Private Service Consumer in each environment that needs to call these services, for example a data plane that calls an API in its control plane. A service becomes reachable over the link once it has an internal [Route](https://ryvn.ai/docs/networking/routes), at the same URL it has here, like `https://<name>.<publisherDomain>`. The link carries HTTP and HTTPS, including gRPC.
