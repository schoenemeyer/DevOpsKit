Set-StrictMode -Version Latest 
class Databricks: SVTBase
{       
    hidden [PSObject] $ResourceObject;
	hidden [string] $ManagedResourceGroupName;
	hidden [string] $WorkSpaceLoction;
	hidden [string] $WorkSpaceBaseUrl = "https://{0}.azuredatabricks.net/api/2.0/";
	hidden [string] $PersonalAccessToken =""; 

    Databricks([string] $subscriptionId, [string] $resourceGroupName, [string] $resourceName): 
                 Base($subscriptionId, $resourceGroupName, $resourceName) 
    { 
	    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$this.GetResourceObject();
    }

    Databricks([string] $subscriptionId, [SVTResource] $svtResource): 
        Base($subscriptionId, $svtResource) 
    { 
	    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$this.GetResourceObject();
    }

	 hidden [PSObject] GetResourceObject()
    {
        if (-not $this.ResourceObject)
		{
		
            $this.ResourceObject = Get-AzureRmResource -Name $this.ResourceContext.ResourceName  `
                                        -ResourceType $this.ResourceContext.ResourceType `
                                        -ResourceGroupName $this.ResourceContext.ResourceGroupName

            if(-not $this.ResourceObject)
            {
				throw ([SuppressedException]::new(("Resource '$($this.ResourceContext.ResourceName)' not found under Resource Group '$($this.ResourceContext.ResourceGroupName)'"), [SuppressedExceptionType]::InvalidOperation))
            }
			else
			{
			   $this.InitializeRequiredVariables();
			   $this.CheckIfUserAdmin();
			}
			
        }

        return $this.ResourceObject;
    }

	
    hidden [ControlResult] CheckVnetPeering([ControlResult] $controlResult)
    {
	    
        $vnetPeerings = Get-AzureRmVirtualNetworkPeering -VirtualNetworkName "workers-vnet" -ResourceGroupName $this.ManagedResourceGroupName
        if($null -ne $vnetPeerings  -and ($vnetPeerings|Measure-Object).count -gt 0)
        {
			$controlResult.AddMessage([VerificationResult]::Verify, [MessageData]::new("Verify below peering found on VNet", $vnetPeerings));
			$controlResult.SetStateData("Peering found on VNet", $vnetPeerings);

        }
        else
        {
			$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("No VNet peering found on VNet", $vnetPeerings));
        }

        return $controlResult;
	}

	 hidden [ControlResult] CheckSecretScope([ControlResult] $controlResult)
    {
	    if(-not [string]::IsNullOrEmpty($this.PersonalAccessToken))
		{
			 $SecretScopes	= $this.InvokeRestAPICall("GET","secrets/scopes/list","")
			 if($null -ne  $SecretScopes  -and ( $SecretScopes|Measure-Object).count -gt 0)
			 {
		       $controlResult.AddMessage([VerificationResult]::Verify, [MessageData]::new("Verify secrets and keys must not be as plain text in notebook"));
             }
			 else
			 {
			   $controlResult.AddMessage([VerificationResult]::Failed, [MessageData]::new("No secret scope found in your workspace."));
             }
		}else
		{
		   $controlResult.AddMessage([VerificationResult]::Manual);
		}
	   

        return $controlResult;
	}

	 hidden [ControlResult] CheckSecretScopeBackend([ControlResult] $controlResult)
    {
	    if(-not [string]::IsNullOrEmpty($this.PersonalAccessToken))
		{
			 $SecretScopes	= $this.InvokeRestAPICall("GET","secrets/scopes/list","")
			 if($null -ne  $SecretScopes  -and ( $SecretScopes|Measure-Object).count -gt 0)
			 {
				  $DatabricksBackedSecret = $SecretScopes.scopes | where {$_.backend_type -ne "AZURE_KEYVAULT"}
				  if($null -ne $DatabricksBackedSecret -and ( $SecretScopes|Measure-Object).count -gt 0)
				  {
					$controlResult.AddMessage([VerificationResult]::Verify, [MessageData]::new("Following Databricks backed secret scope found:", $DatabricksBackedSecret));
					$controlResult.SetStateData("Following Databricks backed secret scope found:", $DatabricksBackedSecret);
				  }
				  else
				  {
					$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("All secret scope in your workspace are KeyVault backed."));
				  }
             }
			 else
			 {
			   $controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("No secret scope found in your workspace."));
             }
		}else
		{
		   $controlResult.AddMessage([VerificationResult]::Manual);
		}
	   

        return $controlResult;
	}

	hidden [ControlResult] CheckKeyVaultReference([ControlResult] $controlResult)
    {
	    if(-not [string]::IsNullOrEmpty($this.PersonalAccessToken))
		{
			$KeyVaultScopeMapping = @()
			$KeyVaultWithMultipleReference = @() 
			$SecretScopes	= $this.InvokeRestAPICall("GET","secrets/scopes/list","")
			if($null -ne  $SecretScopes  -and ( $SecretScopes|Measure-Object).count -gt 0)
			{
			  $KeyVaultBackedSecretScope = $SecretScopes.scopes | where {$_.backend_type -eq "AZURE_KEYVAULT"}
			  if($null -ne $KeyVaultBackedSecretScope -and ( $KeyVaultBackedSecretScope | Measure-Object).count -gt 0)
			  {
				$KeyVaultBackedSecretScope | ForEach-Object {
					$KeyVaultScopeMappingObject = "" | Select-Object "ScopeName", "KeyVaultResourceId"
					$KeyVaultScopeMappingObject.ScopeName = $_.name
					$KeyVaultScopeMappingObject.KeyVaultResourceId = $_.keyvault_metadata.resource_id
					$KeyVaultScopeMapping += $KeyVaultScopeMappingObject
				}
				# Check if same keyvault is referenced by multiple secret scopes
				$KeyVaultWithManyReference = $KeyVaultScopeMapping | Group-object -Property KeyVaultResourceId | Where-Object {$_.Count -gt 1} 
				if($null -ne $KeyVaultWithManyReference -and ($KeyVaultWithManyReference | Measure-Object).Count -gt 0)
				{
					$KeyVaultWithManyReference | ForEach-Object { $KeyVaultWithMultipleReference += $_.Name }
					$controlResult.AddMessage([VerificationResult]::Verify, [MessageData]::new("Following KeyVault(s) are referenced by multiple secret scope:", $KeyVaultWithMultipleReference));
					$controlResult.SetStateData("Following KeyVault(s) are referenced by multiple secret scope:", $KeyVaultWithMultipleReference);

				}else
				{
					$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("All KeyVault backed secret scope are linked with independent KeyVault.", $KeyVaultWithMultipleReference));
				}
			  }
			  else
			  {
				$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("No KeyVault backed secret scope found in your workspace."));
			  }
			}
			else
			{
				$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("No secret scope is found in your workspace."));
			}

		}else
		{
			$controlResult.AddMessage([VerificationResult]::Manual);
		}
	   

        return $controlResult;
	}

	hidden [ControlResult] CheckAccessTokenExpiry([ControlResult] $controlResult)
    {   
	    if(-not [string]::IsNullOrEmpty($this.PersonalAccessToken))
		{
			 $AccessTokens = $this.InvokeRestAPICall("GET","token/list","")
			if($null -ne $AccessTokens -and ($AccessTokens.token_infos| Measure-Object).Count -gt 0)
			{   
			    $PATwithInfiniteValidity =@()
				$PATwithInfiniteValidity += $AccessTokens.token_infos | Where-Object {$_.expiry_time -eq "-1" }
				$PATwithInfiniteValidity += $AccessTokens.token_infos | Where-Object {$_.expiry_time -ne "-1"} | Where-Object { (New-TimeSpan -Seconds (($_.expiry_time - $_.creation_time)/1000)).Days -gt 180 } 
			
				$PATwithFiniteValidity = $AccessTokens.token_infos | Where-Object {$_.expiry_time -ne "-1"}
				if($null -ne $PATwithInfiniteValidity -and ($PATwithInfiniteValidity| Measure-Object).Count -gt 0)
				{
					$controlResult.AddMessage([VerificationResult]::Failed, [MessageData]::new("Following personal access token has validity more than 180 days:", $PATwithInfiniteValidity));
					$controlResult.SetStateData("Following personal access token has validity more than 180 days:", $PATwithInfiniteValidity);

				}
				else
				{
					$controlResult.AddMessage([VerificationResult]::Passed, [MessageData]::new("Following personal access token with finite validity found in your workspace:", $PATwithFiniteValidity));
				}

			}
			else
			{
				$controlResult.AddMessage([VerificationResult]::Manual, [MessageData]::new("No personal access token found in your workspace."));
			}	

		}else
		{
			$controlResult.AddMessage([VerificationResult]::Manual);
		} 
	   
        return $controlResult;
	}

	hidden [ControlResult] CheckAdminAccess([ControlResult] $controlResult)
	{
		$accessList = [RoleAssignmentHelper]::GetAzSKRoleAssignmentByScope($this.GetResourceId(), $false, $true);
		$adminAccessList = $accessList | Where-Object { $_.RoleDefinitionName -eq 'Owner' -or $_.RoleDefinitionName -eq 'Contributor'}
		# Add check for User Type
		$potentialAdminUsers = @()
		$activeAdminUsers =@()
		$adminAccessList | ForEach-Object {
			if([Helpers]::CheckMember($_, "SignInName"))
			{
			   $potentialAdminUsers += $_.SignInName
			}
		}	
		# Get All Active Users
		$requestBody = "group_name=admins"
		$activeAdmins = $this.InvokeRestAPICall("GET","groups/list-members",$requestBody);
		if($null -ne $activeAdmins -and ($activeAdmins | Measure-Object).Count -gt 0)
		{
			$activeAdminUsers += $activeAdmins.members
		}
		if(($potentialAdminUsers|Measure-Object).Count -gt 0)
		{
			$controlResult.AddMessage("Validate that the following identities have potential admin access to resource - [$($this.ResourceContext.ResourceName)]");
			$controlResult.AddMessage([MessageData]::new("", $potentialAdminUsers));
		}
		if(($activeAdminUsers|Measure-Object).Count -gt 0)
		{
			$controlResult.AddMessage("Validate that the following identities have active admin access to resource - [$($this.ResourceContext.ResourceName)]");
			$controlResult.AddMessage([MessageData]::new("", $activeAdminUsers));
		}

		return $controlResult;
	}

	hidden [PSObject] InvokeRestAPICall([string] $method, [string] $operation , [string] $body)
	{   
	     $ResponseObject = $null;
		 try
		 {
			 $uri = $this.WorkSpaceBaseUrl + $operation 
			 if([string]::IsNullOrWhiteSpace($body))
			 {
			   $ResponseObject = Invoke-RestMethod `
							 -Method $method `
							 -Uri $uri `
							 -Headers @{"Authorization" = "Bearer "+$this.PersonalAccessToken} `
							 -ContentType 'application/json'`
							 -UseBasicParsing
			 }else
			 {
			   $uri =  $uri +'?'+ $body
			   $ResponseObject = Invoke-RestMethod `
							 -Method $method `
							 -Uri $uri `
							 -Headers @{"Authorization" = "Bearer "+$this.PersonalAccessToken} `
							 -ContentType 'application/json'`
							 -UseBasicParsing
							
			 }
		 }
		 catch
		 {
		   # No need to break execution
		 } 
		return  $ResponseObject 
	}

	hidden [string] ReadAccessToken()
	{
	    # Write token fetch logic here
		return 'dapi919dd0b1ea90d86e39cd0ac56b153915';
	}

	hidden InitializeRequiredVariables()
	{
		$this.WorkSpaceLoction = $this.ResourceObject.Location
		$count = $this.ResourceObject.Properties.managedResourceGroupId.Split("/").Count
		$this.ManagedResourceGroupName = $this.ResourceObject.Properties.managedResourceGroupId.Split("/")[$count-1]
		$this.WorkSpaceBaseUrl=[system.string]::Format($this.WorkSpaceBaseUrl,$this.WorkSpaceLoction)
		$this.PersonalAccessToken = $this.ReadAccessToken()
	}

	hidden [bool] CheckIfUserAdmin()
	{
	  try
	  {
		  $currentContext = [Helpers]::GetCurrentRMContext()
		  $userId = $currentContext.Account.Id;
		  $requestBody = "user_name="+$userId
		  $parentGroups = $this.InvokeRestAPICall("GET","groups/list-parents",$requestBody)
		  if($parentGroups.group_names.Contains("admins"))
		  {
			  return $true;
		  }else
		  {
			 return $false;
		  }
	  }
	  catch{
		return $false;
	  }
	  
	}

}