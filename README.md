# vSwitchMigration
Switch from old LBFO Team to SET TEAM for Hyper-V and SCVMM

Be aware, this script was used as a tool and should not be used without testing it yourself and adopting to your specific situation.

The NEW switch you create with this script on the Hyper-V host should have the exact same name as the new logical switch you create in SCVMM prior to running this script.

After you've ran this script on the hyper-v host locally, you refresh the host in SCVMM, then connect the host to the earlier created logical switch.
You should now see a "Convert" button on this page, press that to convert.

After all hosts within the custer have been converted, refresh the cluster again.

Note:
You'll on average lose 1 ping.
We've had issues with VMs with snapshots that complained about not being able to commit snapshots because of the old network config.
Don't be scared when VMs suddenly show an empty networking page, this will correct itself after a while.

Source:
This repo was source for this script:
https://github.com/microsoft/Convert-LBFO2SET 
