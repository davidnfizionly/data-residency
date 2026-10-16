# Data residency rules evaluated against a Terraform plan (terraform show -json).
# Any message in `deny` fails the pull request check. Messages are written for a
# non-technical reviewer: they say which tenant or table would leave which region.

package terraform.residency

import rego.v1

zone_region := {"eu": "eu-west-1", "us": "us-east-1"}

# Every resource that will exist after the change (creates, updates, unchanged).
planned contains rc if {
	some rc in input.resource_changes
	not rc.change.actions == ["delete"]
	not rc.change.actions == ["read"]
}

# 1. Tenant routing: a tenant's data must be stored in its contractual region.
deny contains msg if {
	some rc in planned
	rc.type == "aws_lambda_function"
	registry := json.unmarshal(rc.change.after.environment[0].variables.TENANT_REGISTRY)
	some tenant_id, tenant in registry
	tenant.storage_region != tenant.tenant_region
	msg := sprintf(
		"RESIDENCY VIOLATION: tenant %s must stay in %s, but this change would route its personal data to %s.",
		[tenant_id, tenant.tenant_region, tenant.storage_region],
	)
}

# 2. Data plane wiring: each region must point at the data plane of its own zone.
deny contains msg if {
	some rc in planned
	rc.type == "aws_lambda_function"
	planes := json.unmarshal(rc.change.after.environment[0].variables.DATA_PLANES)
	some region, plane in planes
	zone_region[plane.zone] != region
	msg := sprintf(
		"RESIDENCY VIOLATION: writes for %s would go to the %s data plane, which belongs to %s.",
		[region, plane.zone, zone_region[plane.zone]],
	)
}

# 3. PII tables must be created in the home region of their residency zone.
deny contains msg if {
	some rc in planned
	rc.type == "aws_dynamodb_table"
	tags := rc.change.after.tags
	tags.DataClassification == "pii"
	expected := zone_region[tags.ResidencyZone]
	tags.HomeRegion != expected
	msg := sprintf(
		"RESIDENCY VIOLATION: PII table %s belongs to zone %s and must be in %s, but this change would create it in %s.",
		[rc.change.after.name, tags.ResidencyZone, expected, tags.HomeRegion],
	)
}

deny contains msg if {
	some rc in planned
	rc.type == "aws_dynamodb_table"
	rc.change.after.tags.DataClassification == "pii"
	not zone_region[rc.change.after.tags.ResidencyZone]
	msg := sprintf("RESIDENCY VIOLATION: PII table %s has no valid ResidencyZone tag (eu or us).", [rc.change.after.name])
}

# 4. No copy of PII or logs to another region.
deny contains msg if {
	some rc in planned
	rc.type == "aws_dynamodb_table"
	rc.change.after.tags.DataClassification == "pii"
	count(object.get(rc.change.after, "replica", [])) > 0
	msg := sprintf("RESIDENCY VIOLATION: PII table %s would be replicated to another region.", [rc.change.after.name])
}

deny contains msg if {
	some rc in planned
	rc.type in {"aws_s3_bucket_replication_configuration", "aws_dynamodb_table_replica"}
	msg := sprintf("RESIDENCY VIOLATION: %s would copy data to another region.", [rc.address])
}
