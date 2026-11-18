OMBRA - SINGLE VM EDITION - INSTALLER
=====================================

This disc installs Ombra into one virtual machine on your Mac. Everything
on the virtual disk is erased and encrypted. The installer asks two
things: the account password and the disk passphrase. Everything else
is preset.

Tested on VMware Fusion. Not yet tested on UTM.


WHAT YOU NEED
-------------

  Mac            Apple Silicon (M1 or newer)
  App            VMware Fusion (tested) or UTM (untested)
  Guest type     Linux, 64-bit ARM (arm64)
  CPU            4 cores recommended
  Memory         6 GB recommended (3 GB minimum)
  Disk           30 GB recommended (24 GB minimum)
  Network        one adapter, on NAT ("Share with my Mac" in Fusion,
                 "Shared Network" in UTM). The Mac must be online: the
                 installer downloads Debian packages directly, not
                 through Tor
  Keyboard       US layout: the installer and the unlock screen both
                 read keys as a US keyboard

In the app, also turn off: clipboard sharing, drag and drop, shared
folders and snapshots. Shut the VM down instead of suspending it.
Ombra removes the clipboard, drag-and-drop and shared-folder helpers
inside the VM, but it cannot change the app's settings.


THREE STEPS
-----------

  1. Create the virtual machine with the settings above and attach
     this ISO file as its CD/DVD drive.

  2. Start it. The installer starts by itself after 3 seconds; there
     is nothing to type at the boot menu.

  3. Answer the two questions:
       - Password for the account "ombra", twice.
       - Disk encryption passphrase, twice. At least 8 characters
         (a shorter one is asked again). You type it at every start.
         It cannot be recovered if you forget it.

     The install then runs on its own and restarts into Ombra. How
     long it takes depends on your network (about 5 to 10 minutes on
     a fast connection in testing). Remove the ISO from the CD/DVD
     drive if the app does not do it.


AFTER THE INSTALL
-----------------

  - Every start shows a boot menu: Persistent or Amnesic. Then the
    disk passphrase, then the login screen asks for the password.
  - The account is not an administrator. Root login is disabled.
  - All traffic leaves through Tor, which runs inside the same VM.
    If Tor's side is not running, the VM has no network.
