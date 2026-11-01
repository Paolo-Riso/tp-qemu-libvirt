#!/bin/bash
# Importe Metasploitable2 sur le réseau isolé lab-isole
virt-install \
  --name metasploitable2 \
  --memory 512 \
  --vcpus 1 \
  --disk path=/var/lib/libvirt/images/metasploitable2.qcow2,format=qcow2,bus=ide \
  --import \
  --os-variant ubuntu8.04 \
  --network network=lab-isole,model=e1000 \
  --graphics vnc \
  --noautoconsole
