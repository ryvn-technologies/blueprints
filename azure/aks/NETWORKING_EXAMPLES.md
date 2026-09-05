# Azure AKS Networking - Subnet Allocation Examples

This document shows how subnets are allocated for different VNet sizes and CNI modes.

## Mode-Aware Allocation Strategy

The Terraform configuration automatically adjusts subnet allocation based on:
1. **VNet size** (compact /22-/24, standard /19-/21, large /16-/18)
2. **CNI mode** (overlay vs flat)

### Why Mode-Aware?

**Overlay Mode:**
- Nodes need only 1 IP each
- A /24 subnet = ~251 nodes
- Infrastructure needs fixed ~64-128 IPs
- **Strategy:** Maximize node space, minimize infrastructure

**Flat Mode:**
- Nodes + pods share IPs (~100 IPs per node if max_pods=100)
- A /24 subnet = ~2 nodes
- **Strategy:** Balance node and infrastructure space

---

## Example Configurations

### 1. Large VNet: /16 (65,536 IPs)

#### Overlay mode (the default)
```
VNet: 10.0.0.0/16 (65,536 IPs)
├── Node Space: 10.0.0.0/17 (32,768 IPs)
│   ├── private-1: 10.0.0.0/19 (8,192 IPs) → ~8,187 nodes
│   ├── private-2: 10.0.32.0/19 (8,192 IPs) → ~8,187 nodes
│   └── private-3: 10.0.64.0/19 (8,192 IPs) → ~8,187 nodes
│
└── Infrastructure: 10.0.128.0/17 (32,768 IPs)
    ├── appgw-subnet: 10.0.128.0/24 (256 IPs)
    └── privatelink-subnet: 10.0.129.0/24 (256 IPs)

Total capacity: ~24,561 nodes (far exceeds AKS 5000 node limit)
Pod CIDR: 192.168.0.0/16 (separate overlay network)
```

#### Flat mode
```
VNet: 10.0.0.0/16 (65,536 IPs)
├── Node Space: 10.0.0.0/17 (32,768 IPs)
│   ├── private-1: 10.0.0.0/19 (8,192 IPs) → ~81 nodes @ 100 pods/node
│   ├── private-2: 10.0.32.0/19 (8,192 IPs) → ~81 nodes
│   └── private-3: 10.0.64.0/19 (8,192 IPs) → ~81 nodes
│
└── Infrastructure: 10.0.128.0/17 (32,768 IPs)
    ├── appgw-subnet: 10.0.128.0/24 (256 IPs)
    └── privatelink-subnet: 10.0.129.0/24 (256 IPs)

Total capacity: ~243 nodes @ 100 pods/node
Pods share VNet IPs with nodes
```

---

### 2. Standard VNet: /20 (4,096 IPs)

#### Overlay mode (the default)
```
VNet: 10.10.0.0/20 (4,096 IPs)
├── Node Space: 10.10.0.0/21 (2,048 IPs)
│   ├── private-1: 10.10.0.0/23 (512 IPs) → ~507 nodes
│   ├── private-2: 10.10.2.0/23 (512 IPs) → ~507 nodes
│   └── private-3: 10.10.4.0/23 (512 IPs) → ~507 nodes
│
└── Infrastructure: 10.10.8.0/21 (2,048 IPs)
    ├── appgw-subnet: 10.10.8.0/25 (128 IPs)
    └── privatelink-subnet: 10.10.8.128/25 (128 IPs)

Total capacity: ~1,521 nodes
Pod CIDR: 192.168.0.0/16 (separate overlay network)
```

#### Flat Mode
```
VNet: 10.10.0.0/20 (4,096 IPs)
├── Node Space: 10.10.0.0/21 (2,048 IPs)
│   ├── private-1: 10.10.0.0/23 (512 IPs) → ~5 nodes @ 100 pods/node
│   ├── private-2: 10.10.2.0/23 (512 IPs) → ~5 nodes
│   └── private-3: 10.10.4.0/23 (512 IPs) → ~5 nodes
│
└── Infrastructure: 10.10.8.0/21 (2,048 IPs)
    ├── appgw-subnet: 10.10.8.0/25 (128 IPs)
    └── privatelink-subnet: 10.10.8.128/25 (128 IPs)

Total capacity: ~15 nodes @ 100 pods/node — too few for most workloads.
```

---

### 3. Compact VNet: /23 (512 IPs)

#### Overlay mode (the only workable choice at this size)
```
VNet: 10.10.0.0/23 (512 IPs)
├── Node Space: 10.10.0.0/24 (256 IPs)
│   ├── private-1: 10.10.0.0/26 (64 IPs) → ~59 nodes
│   ├── private-2: 10.10.0.64/26 (64 IPs) → ~59 nodes
│   └── private-3: 10.10.0.128/26 (64 IPs) → ~59 nodes
│
└── Infrastructure: 10.10.1.0/24 (256 IPs)
    ├── appgw-subnet: 10.10.1.0/26 (64 IPs)
    └── privatelink-subnet: 10.10.1.64/26 (64 IPs)

Total capacity: ~177 nodes
Pod CIDR: 192.168.0.0/16 (separate overlay network)
Workable for small and medium clusters.
```

#### Flat mode (unusable at this size)
```
VNet: 10.10.0.0/23 (512 IPs)
├── Node Space: 10.10.0.0/24 (256 IPs)
│   ├── private-1: 10.10.0.0/26 (64 IPs) → ~0 nodes @ 100 pods/node
│   ├── private-2: 10.10.0.64/26 (64 IPs) → ~0 nodes
│   └── private-3: 10.10.0.128/26 (64 IPs) → ~0 nodes
│
└── Infrastructure: 10.10.1.0/24 (256 IPs)
    ├── appgw-subnet: 10.10.1.0/26 (64 IPs)
    └── privatelink-subnet: 10.10.1.64/26 (64 IPs)

Total capacity: ~1 node @ 100 pods/node — do not use flat mode with a /23.
```

---

## Key Takeaways

### VNet Size Recommendations

| VNet Size | Total IPs | Overlay Capacity | Flat Capacity | Recommendation |
|-----------|-----------|------------------|---------------|----------------|
| /16       | 65,536    | ~24K nodes       | ~243 nodes    | Either mode works |
| /20       | 4,096     | ~1,521 nodes     | ~15 nodes     | Overlay preferred |
| /23       | 512       | ~177 nodes       | ~1 node       | Overlay required |
| /24       | 256       | ~59 nodes        | ~0 nodes      | Overlay only |

### When to Use Each Mode

**Overlay** (the module default) when:
- the VNet is /20 or smaller
- more than ~100 nodes are needed
- the same pod CIDR should be reusable across clusters

**Flat** when:
- a /16 or /17 is available
- pod IPs must be routable directly from on-premises networks
- fewer than ~200 nodes are needed

The mode cannot be changed on a live cluster; switching replaces it.

### Example Input Combinations

**Small cluster with /23 VNet:**
```hcl
vnet_cidr           = "10.10.0.0/23"
network_plugin_mode = "overlay" # required at this size
pod_cidr            = "192.168.0.0/16"
```

**Medium cluster with /20 VNet:**
```hcl
vnet_cidr           = "10.10.0.0/20"
network_plugin_mode = "overlay" # the default
pod_cidr            = "192.168.0.0/16"
```

**Large cluster with /16 VNet, pod IPs routable from on-premises:**
```hcl
vnet_cidr           = "10.0.0.0/16"
network_plugin_mode = "flat"
# pod_cidr is unused in flat mode
```

---

## Capacity Planning

### Overlay Mode Formula
```
Nodes per subnet = (Subnet IPs - 5 reserved)
Total capacity = Nodes per subnet × 3 subnets
```

### Flat Mode Formula
```
IPs per node = max_pods_per_node (typically 100)
Nodes per subnet = (Subnet IPs - 5) / IPs per node
Total capacity = Nodes per subnet × 3 subnets
```

### AKS Limits
- Azure CNI (flat): Max 1,000 nodes per cluster
- Azure CNI Overlay: Max 5,000 nodes per cluster
- Max pods per node: 250 (overlay), 250 (flat with proper config)
