locals {
  dns_records = {
    for key, config in local.hostnames : key => config.dns_record
  }
}

resource "cloudflare_dns_record" "this" {
  for_each = local.dns_records

  zone_id         = var.zone_id
  name            = each.value.name
  type            = upper(each.value.type)
  content         = each.value.content
  data            = null
  ttl             = each.value.ttl
  proxied         = each.value.proxied
  comment         = try(each.value.comment, null)
  priority        = null
  private_routing = null
  settings        = null
  tags            = []
}
