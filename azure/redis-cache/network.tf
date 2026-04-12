# Private endpoint for Azure Private Link
resource "azurerm_private_endpoint" "redis" {
  count               = local.private_link_enabled ? 1 : 0
  name                = "${local.name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = local.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${local.name}-psc"
    private_connection_resource_id = azurerm_redis_cache.this.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.private_dns_zone_id]
  }
}

# --- Public access firewall rules (when Private Link is not used) ---

locals {
  # Lookup table: prefix length -> last host number (2^(32-N) - 1)
  _max_host = {
    0  = 4294967295, 1 = 2147483647, 2 = 1073741823, 3 = 536870911,
    4  = 268435455, 5 = 134217727, 6 = 67108863, 7 = 33554431,
    8  = 16777215, 9 = 8388607, 10 = 4194303, 11 = 2097151,
    12 = 1048575, 13 = 524287, 14 = 262143, 15 = 131071,
    16 = 65535, 17 = 32767, 18 = 16383, 19 = 8191,
    20 = 4095, 21 = 2047, 22 = 1023, 23 = 511,
    24 = 255, 25 = 127, 26 = 63, 27 = 31,
    28 = 15, 29 = 7, 30 = 3, 31 = 1, 32 = 0
  }

  # Normalize: bare IPs get /32
  _normalized_cidrs = [for cidr in var.allowed_cidr_blocks :
    length(regexall("/", cidr)) > 0 ? cidr : "${cidr}/32"
  ]

  # Convert CIDRs to start/end IP ranges for Azure firewall rules
  _cidr_rules = { for i, cidr in local._normalized_cidrs : "allow-${i}" => {
    start_ip = cidrhost(cidr, 0)
    end_ip   = cidrhost(cidr, local._max_host[tonumber(split("/", cidr)[1])])
  } }
}

# Firewall rules (public access mode only)
resource "azurerm_redis_firewall_rule" "this" {
  for_each = !local.private_link_enabled ? local._cidr_rules : {}

  name                = each.key
  redis_cache_name    = azurerm_redis_cache.this.name
  resource_group_name = var.resource_group_name
  start_ip            = each.value.start_ip
  end_ip              = each.value.end_ip
}
