# Separate-state external compute consumer. Consumes the versioned attachment
# descriptor exported by the root module (terraform output -json egress_firewall
# > attachments.json) and places a probe VM NIC in the covered subnet.
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "= 4.81.0" }
  }
}
provider "azurerm" {
  resource_provider_registrations = "none"
  features {}
}

variable "attachments_file" { type = string }
variable "attachment_key" { type = string }
variable "ssh_public_key" { type = string }
variable "expected_vnet_id" {
  type    = string
  default = null
}
variable "create_bypass_vm" {
  type    = bool
  default = false
}
# Gives the bypass VM a public IP so it doubles as the instrumented controlled
# origin (see ../origin-server.py): protected probes reach it only through the
# firewall, and its byte log is the ground truth for what escaped.
variable "create_origin_public_ip" {
  type    = bool
  default = false
}

locals {
  egress      = jsondecode(file(var.attachments_file))
  attachments = try(local.egress.attachments, {})
  attachment  = lookup(local.attachments, var.attachment_key, null)
}

check "attachment_descriptor" {
  assert {
    condition     = local.attachment != null
    error_message = "attachment '${var.attachment_key}' is not exported by the firewall root (available: ${join(",", keys(local.attachments))}). Disabled roots export {}."
  }
}

resource "terraform_data" "attachment_contract" {
  lifecycle {
    precondition {
      condition     = local.attachment != null
      error_message = "attachment '${var.attachment_key}' missing from ${var.attachments_file}."
    }
    precondition {
      condition     = try(local.attachment.schema_version, 0) == 1 && try(local.attachment.provider, "") == "azure"
      error_message = "attachment descriptor must be schema_version=1 provider=azure (got version=${try(local.attachment.schema_version, "?")} provider=${try(local.attachment.provider, "?")})."
    }
    precondition {
      condition     = var.expected_vnet_id == null || try(local.attachment.virtual_network_id, "") == var.expected_vnet_id
      error_message = "attachment descriptor is stale: virtual_network_id does not match the expected VNet."
    }
  }
}

data "azurerm_subnet" "attached" {
  name                 = element(split("/", local.attachment.subnet_id), length(split("/", local.attachment.subnet_id)) - 1)
  virtual_network_name = element(split("/", local.attachment.virtual_network_id), length(split("/", local.attachment.virtual_network_id)) - 1)
  resource_group_name  = local.attachment.resource_group_name
  depends_on           = [terraform_data.attachment_contract]

  lifecycle {
    postcondition {
      condition     = self.route_table_id == local.attachment.route_table_id
      error_message = "attachment subnet is not covered by the firewall route table (uncovered attachment)."
    }
  }
}

resource "azurerm_network_interface" "probe" {
  name                = "egfw-probe-nic"
  location            = local.attachment.location
  resource_group_name = local.attachment.resource_group_name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = data.azurerm_subnet.attached.id
    private_ip_address_allocation = "Dynamic"
  }
  tags = { Disposable = "true", Owner = "devin-egress-firewall-validation" }
}

resource "azurerm_linux_virtual_machine" "probe" {
  name                            = "egfw-probe"
  location                        = local.attachment.location
  resource_group_name             = local.attachment.resource_group_name
  size                            = "Standard_B2als_v2"
  admin_username                  = "probe"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.probe.id]
  admin_ssh_key {
    username   = "probe"
    public_key = var.ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  tags = { Disposable = "true", Owner = "devin-egress-firewall-validation" }
}

# Bypass attempt: a NIC in a subnet the root never attached (no UDR). Proves
# what an uncovered placement can reach.
resource "azurerm_subnet" "uncovered" {
  count                = var.create_bypass_vm ? 1 : 0
  name                 = "egfw-uncovered"
  resource_group_name  = local.attachment.resource_group_name
  virtual_network_name = data.azurerm_subnet.attached.virtual_network_name
  address_prefixes     = ["10.0.97.0/28"]
}

resource "azurerm_public_ip" "origin" {
  count               = var.create_bypass_vm && var.create_origin_public_ip ? 1 : 0
  name                = "egfw-origin-pip"
  location            = local.attachment.location
  resource_group_name = local.attachment.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = { Disposable = "true" }
}

# Standard-SKU public IPs are closed to inbound traffic until an NSG allows it.
resource "azurerm_network_security_group" "origin" {
  count               = var.create_bypass_vm && var.create_origin_public_ip ? 1 : 0
  name                = "egfw-origin-nsg"
  location            = local.attachment.location
  resource_group_name = local.attachment.resource_group_name
  tags                = { Disposable = "true" }

  security_rule {
    name                       = "allow-web-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "origin" {
  count                     = var.create_bypass_vm && var.create_origin_public_ip ? 1 : 0
  network_interface_id      = azurerm_network_interface.bypass[0].id
  network_security_group_id = azurerm_network_security_group.origin[0].id
}

resource "azurerm_network_interface" "bypass" {
  count               = var.create_bypass_vm ? 1 : 0
  name                = "egfw-bypass-nic"
  location            = local.attachment.location
  resource_group_name = local.attachment.resource_group_name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.uncovered[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = try(azurerm_public_ip.origin[0].id, null)
  }
  tags = { Disposable = "true" }
}

resource "azurerm_linux_virtual_machine" "bypass" {
  count                           = var.create_bypass_vm ? 1 : 0
  name                            = "egfw-bypass"
  location                        = local.attachment.location
  resource_group_name             = local.attachment.resource_group_name
  size                            = "Standard_B2als_v2"
  admin_username                  = "probe"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.bypass[0].id]
  admin_ssh_key {
    username   = "probe"
    public_key = var.ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  tags = { Disposable = "true" }
}

output "probe_private_ip" { value = azurerm_network_interface.probe.private_ip_address }
output "bypass_private_ip" { value = try(azurerm_network_interface.bypass[0].private_ip_address, null) }
output "origin_public_ip" { value = try(azurerm_public_ip.origin[0].ip_address, null) }
# Provider-resolvable controlled names: <a-b-c-d>.sslip.io resolves to a.b.c.d for
# any label depth, so *.<origin>.sslip.io is a real wildcard base with a resolvable
# apex, one-label child and multi-label descendants that all land on the origin.
output "origin_controlled_domain" { value = try("${replace(azurerm_public_ip.origin[0].ip_address, ".", "-")}.sslip.io", null) }
