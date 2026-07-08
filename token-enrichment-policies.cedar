permit (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getRole",
    resource is TokenEnrichment::AppRole
) 
when
{
  (resource.parentApplication has assignedGroups &&
   principal has assignedGroups &&
   resource.parentApplication
     .assignedGroups
     .containsAny
     (
       principal.assignedGroups
     )) ||
  (resource.parentApplication has allowedUsers &&
   resource.parentApplication.allowedUsers.contains(principal))
};

permit (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getRole",
    resource is TokenEnrichment::AppRole
) 
when
{
  principal.active == true &&
  principal has userSource &&
  principal.userSource == "okta" &&
  ((resource.parentApplication has assignedGroups &&
    principal has assignedGroups &&
    resource.parentApplication
      .assignedGroups
      .containsAny
      (
        principal.assignedGroups
      )) ||
   (resource.parentApplication has allowedUsers &&
    resource.parentApplication.allowedUsers.contains(principal)))
};

forbid (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getApplication",
    resource is TokenEnrichment::Application
) 
when
{ principal has suspendedApps && principal.suspendedApps.contains(resource) };

forbid (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getRole",
    resource is TokenEnrichment::AppRole
) 
when { principal.active == false };

permit (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getApplication",
    resource is TokenEnrichment::Application
) 
when
{
  principal.active == true &&
  principal has userSource &&
  principal.userSource == "External" &&
  ((resource has assignedGroups &&
    principal has assignedGroups &&
    resource.assignedGroups.containsAny(principal.assignedGroups)) ||
   (resource has allowedUsers && resource.allowedUsers.contains(principal)))
};

permit (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getApplication",
    resource is TokenEnrichment::Application
) 
when
{
  (resource has assignedGroups &&
   principal has assignedGroups &&
   resource.assignedGroups.containsAny(principal.assignedGroups)) ||
  (resource has allowedUsers && resource.allowedUsers.contains(principal))
};

forbid (
    principal is TokenEnrichment::User,
    action == TokenEnrichment::Action::"getRole",
    resource is TokenEnrichment::AppRole
) 
when
{
  principal has suspendedApps &&
  principal.suspendedApps.contains(resource.parentApplication)
};

permit (
    principal is TokenEnrichment::MachineId,
    action == TokenEnrichment::Action::"getEntitlement",
    resource is TokenEnrichment::Entitlement
) 
when
{
  resource.parentApplication has clientId &&
  resource.parentApplication.clientId == principal
};
