# Private Link service (Azure)

Publishes a Standard Load Balancer frontend as an [Azure Private Link service](https://learn.microsoft.com/azure/private-link/private-link-service-overview). VNets in other subscriptions and regions reach it through private endpoints.

- Picks the frontend by name, or by the IP address of a LoadBalancer Service on an AKS cluster.
- Creates the NAT subnet that consumer traffic arrives from, as the first /28 of a free address range in the load balancer's VNet.
- Shows the service to the subscriptions you list, or only this one if you list none.
- Approves connections from the subscriptions on its auto-approval list. Requests from other subscriptions that can see the service wait for manual approval.
- Outputs the service ID and alias, which consumers connect to.

The `private-endpoint` module is the consumer side.

## On Ryvn

The Private Service Publisher blueprint installs this module in the environment that runs your services and publishes the frontend of the environment's managed internal gateway. It creates the NAT subnet in the VNet's reserved service subnet range. It shows the service to the subscriptions in `azureAllowedSubscriptions` (this subscription if empty) and approves their connections automatically. Its `publisherId` output is the service ID.

Install Private Service Consumer in each environment that needs to call these services, for example a data plane that calls an API in its control plane. A service becomes reachable over the link once it has an internal [Route](https://ryvn.ai/docs/networking/routes), at the same URL it has here, like `https://<name>.<publisherDomain>`. The link carries HTTP and HTTPS, including gRPC.
