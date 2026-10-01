# Private Service Connect publisher (GCP)

Publishes a GKE internal passthrough Network Load Balancer as a [Private Service Connect](https://docs.cloud.google.com/vpc/docs/about-vpc-hosted-services) service attachment. VPCs in other projects reach it through Private Service Connect endpoints in the same region.

- Finds the load balancer by the Kubernetes Service that owns it (`<namespace>/<name>`).
- Creates the NAT subnet that consumer traffic arrives from (`198.18.0.0/28` by default), and a firewall rule that lets that range reach the load balancer on TCP 80 and 443.
- Accepts connections from the projects you list, or only this project if you list none. Removing a project from the list disconnects it.
- Outputs the service attachment ID, which consumers connect to.

The `private-service-consumer` module is the consumer side.

## On Ryvn

The Private Service Publisher blueprint installs this module in the environment that runs your services and publishes the environment's managed internal gateway. It accepts the projects in `gcpAllowedProjects` (this project if empty) and takes the NAT range from `gcpNatSubnetCidr`. Its `publisherId` output is the service attachment ID.

Install Private Service Consumer in each environment in the same region that needs to call these services, for example a data plane that calls an API in its control plane. A service becomes reachable over the link once it has an internal [Route](https://ryvn.ai/docs/networking/routes), at the same URL it has here, like `https://<name>.<publisherDomain>`. The link carries HTTP and HTTPS, including gRPC.
