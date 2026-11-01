# TP QEMU, KVM & libvirt

Mise en place d'un environnement de virtualisation complet (QEMU, KVM, libvirt, virt-install) et d'un mini-lab offensif isolé, dans une VM Debian 13 hébergée sous VMware.

## Sommaire

- [Architecture](#architecture)
- [1. Installation de la pile de virtualisation](#1-installation-de-la-pile-de-virtualisation)
- [2. Réseau virtuel isolé](#2-réseau-virtuel-isolé)
- [3. VM victime : Metasploitable2](#3-vm-victime--metasploitable2)
- [4. VM attaquant : Kali Linux](#4-vm-attaquant--kali-linux)
- [5. Scan et vulnérabilités identifiées](#5-scan-et-vulnérabilités-identifiées)
- [6. Incident simulé et remédiation](#6-incident-simulé-et-remédiation)
- [7. Provisioning automatisé avec cloud-init](#7-provisioning-automatisé-avec-cloud-init)
- [Choix techniques et limites](#choix-techniques-et-limites)
- [Arborescence du dépôt](#arborescence-du-dépôt)

## Architecture

Hôte Debian 13 (VM sous VMware, virtualisation imbriquée)
│
├── Réseau libvirt “default” (NAT, inactif, non utilisé)
│
└── Réseau libvirt “lab-isole” (10.10.10.0/24, sans forward → aucune sortie Internet)
├── metasploitable2 (10.10.10.100) — cible vulnérable
├── kali (10.10.10.x) — machine d’attaque
└── cloudinit-demo (10.10.10.x) — démonstration de provisioning automatisé

Les trois VM invitées ne sont reliées qu'au réseau `lab-isole`. Ce réseau ne définit aucune balise `<forward>`, donc libvirt ne configure ni NAT ni routage : les VM communiquent entre elles et avec l'hôte, mais n'ont aucun accès à Internet.

## 1. Installation de la pile de virtualisation

Paquets installés : `qemu-system-x86`, `libvirt-daemon-system`, `libvirt-clients`, `virtinst`, `virt-manager`, `dnsmasq-base`, `cpu-checker`, `cloud-image-utils`.

Vérification de la virtualisation matérielle et des droits :

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
/usr/sbin/kvm-ok
sudo adduser $USER libvirt
sudo adduser $USER kvm
```

<img width="838" height="213" alt="Capture d&#39;écran 2026-10-31 165923" src="https://github.com/user-attachments/assets/a71d75b2-11bd-4850-ab35-ee9ab9932230" />

**Stockage** : le disque système (19 Go) étant trop petit pour héberger les images de VM, une partition dédiée de 60 Go (`/dev/sda3`) a été créée et montée sur `/var/lib/libvirt/images`, séparant ainsi le système de l'hôte du stockage des VM.

## 2. Réseau virtuel isolé

Fichier : [`networks/lab-isole.xml`](networks/lab-isole.xml).

```xml
<network>
  <name>lab-isole</name>
  <bridge name='virbr-lab' stp='on' delay='0'/>
  <ip address='10.10.10.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.10.10.10' end='10.10.10.100'/>
    </dhcp>
  </ip>
</network>
```

Point clé : **l'absence de balise `<forward>`** est ce qui isole ce réseau. Sans elle, libvirt ne met en place ni NAT ni routage vers l'extérieur : les VM obtiennent une adresse par DHCP et peuvent joindre l'hôte (`10.10.10.1`), mais aucune route ne mène plus loin.

```bash
virsh net-define networks/lab-isole.xml
virsh net-start lab-isole
virsh net-autostart lab-isole
```

### Preuve de l'isolation

Depuis Metasploitable2 et depuis Kali :

```bash
ping -c 3 10.10.10.1    # répond : l'hôte est joignable
ping -c 3 8.8.8.8        # échoue : "Network is unreachable"
```

<img width="954" height="295" alt="ping 10 10 10 1" src="https://github.com/user-attachments/assets/bc200379-70aa-408a-8337-3928be26e4a6" />
<img width="953" height="90" alt="ping 8 8 8 8" src="https://github.com/user-attachments/assets/202f277d-c122-423b-bd34-1121a3ab84d6" />
<img width="955" height="702" alt="ifconfig" src="https://github.com/user-attachments/assets/08ee05d7-d379-4c2e-8823-24038d3f9d46" />


## 3. VM victime : Metasploitable2

Disque fourni au format VMDK, converti en qcow2 :

```bash
sudo qemu-img convert -p -f vmdk -O qcow2 Metasploitable.vmdk metasploitable2.qcow2
```

Script de création : [`scripts/create-metasploitable2.sh`](scripts/create-metasploitable2.sh). Définition exportée : [`vms/metasploitable2.xml`](vms/metasploitable2.xml).

Points notables :
- `bus=ide` et `model=e1000` : Metasploitable2 repose sur un noyau Linux 2.6 (2008), incompatible avec les périphériques virtio modernes.
- Un snapshot `etat-propre` a été créé juste après l'import, servant de point de retour pour la remédiation.

## 4. VM attaquant : Kali Linux

Image officielle QEMU (disque qcow2 déjà installé), importée sans passer par un installateur. Définition exportée : [`vms/kali.xml`](vms/kali.xml).

```bash
virt-install --name kali --memory 2048 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/kali-linux-2026.3-qemu-amd64.qcow2,format=qcow2,bus=virtio \
  --import --os-variant debian13 \
  --network network=lab-isole,model=virtio \
  --graphics spice --noautoconsole
```

Kali utilise `virtio` (disque et réseau) car c'est un système moderne, contrairement à Metasploitable2.

## 5. Scan et vulnérabilités identifiées

Scan réalisé depuis Kali :

```bash
nmap -sV -T4 10.10.10.100 -oN scan-services.txt
```


<img width="1078" height="798" alt="Capture d&#39;écran 2026-11-01 174910" src="https://github.com/user-attachments/assets/ff3d8ea7-4305-4897-85ec-ad9ab3fc336e" />


Ce scan identifie des bannières de version, pas des vulnérabilités confirmées par exploitation : c'est une étape d'identification (mesure du niveau de sécurité), qui prépare la démonstration d'incident ci-dessous.

| Service | Version | Vulnérabilité | Remédiation |
|---|---|---|---|
| vsftpd (port 21) | 2.3.4 | Porte dérobée insérée dans une archive officielle compromise en 2011 ; ouvre un shell root sans authentification via un identifiant contenant `:)` | Mettre à jour vers une version récente, ou désactiver le service |
| Telnet (port 23) | Linux telnetd | Protocole non chiffré : identifiants et trafic transmis en clair | Désactiver Telnet, utiliser SSH à la place |
| Samba (ports 139/445) | smbd 3.X–4.X | Vulnérabilité d'exécution de code à distance connue sur cette plage de versions (faille usermap_script) | Mettre à jour Samba, restreindre l'accès par pare-feu |
| UnrealIRCd (port 6667) | — | Porte dérobée historique insérée dans une archive de distribution compromise, permettant l'exécution de commandes arbitraires | Mettre à jour ou désinstaller le service |

Constat complémentaire : un shell root est directement en écoute sur le port 1524 (bindshell), sans authentification — exemple de mauvaise configuration volontaire propre à Metasploitable2.

## 6. Incident simulé et remédiation

**Scénario** : connexion à la victime et dépôt d'un fichier simulant une intrusion.

```bash
ssh -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa msfadmin@10.10.10.100
touch /tmp/preuve-intrusion.txt
echo "incident simulé $(date)" > /tmp/preuve-intrusion.txt
```


<img width="1089" height="814" alt="Capture d&#39;écran 2026-11-01 174944" src="https://github.com/user-attachments/assets/d7a6ef74-e0f6-46b3-85c2-e88d93bbf65c" />

> Remarque : la connexion SSH nécessite d'autoriser explicitement les anciens algorithmes `ssh-rsa`, désactivés par défaut dans les clients SSH récents — une illustration supplémentaire de l'obsolescence de cette machine.

**Remédiation** : retour à l'état sauvegardé avant toute altération.

```bash
virsh shutdown metasploitable2    # ou virsh destroy si l'arrêt est trop lent
virsh snapshot-revert metasploitable2 etat-propre
virsh start metasploitable2
```

**Vérification** : le fichier a disparu, confirmant le retour à l'état propre.

```bash
ssh -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa msfadmin@10.10.10.100
ls -la /tmp/
```

<img width="1089" height="590" alt="Capture d&#39;écran 2026-11-01 191129" src="https://github.com/user-attachments/assets/bf74f2c2-d6bd-4b4f-8700-8e3454e87931" />


## 7. Provisioning automatisé avec cloud-init

Une VM dédiée (`cloudinit-demo`) démontre le provisioning automatique, sans aucune installation manuelle, à partir d'une image Debian cloud.

Fichiers : [`cloud-init/user-data`](cloud-init/user-data), [`cloud-init/meta-data`](cloud-init/meta-data), définition exportée [`vms/cloudinit-demo.xml`](vms/cloudinit-demo.xml).

```yaml
#cloud-config
ssh_pwauth: true
hostname: cloudinit-demo
users:
  - name: demo
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: 'demo'

runcmd:
  - echo "Provisionné automatiquement par cloud-init le $(date)" > /etc/motd
  - touch /home/demo/preuve-cloudinit.txt
```

Génération du disque de configuration et création de la VM :

```bash
cloud-localds cloudinit-demo-seed.iso user-data meta-data
virt-install --name cloudinit-demo --memory 512 --vcpus 1 \
  --disk path=cloudinit-demo.qcow2,format=qcow2,bus=virtio \
  --disk path=cloudinit-demo-seed.iso,device=cdrom \
  --import --os-variant debian13 \
  --network network=lab-isole,model=virtio \
  --graphics spice --noautoconsole
```

**Preuves de fonctionnement** :

```bash
ssh demo@<adresse>
cat /etc/motd
ls -la /home/demo/
hostname
```


<img width="1077" height="669" alt="Capture d&#39;écran 2026-11-01 201028" src="https://github.com/user-attachments/assets/4c547db7-1a43-492d-8381-e862e83072c2" />


> Remarque : l'option `ssh_pwauth: true` est nécessaire car cloud-init n'active pas l'authentification par mot de passe sur SSH par défaut, même quand un mot de passe est défini pour l'utilisateur. Sans elle, seule une connexion par clé est acceptée.
>
> Limite connue : le paquet `htop` prévu initialement dans la configuration n'a pas pu être installé automatiquement, car `lab-isole` n'offre aucun accès Internet. Cette section a été retirée de la configuration retenue, ce qui illustre un compromis réel entre isolation réseau et provisioning automatisé.

## Choix techniques et limites

- **Partition dédiée pour les images** (`/var/lib/libvirt/images` sur `/dev/sda3`, 60 Go) : évite de saturer le disque système, et sépare proprement l'hôte du stockage des VM.
- **Réseau isolé sans `<forward>`** : l'isolation repose sur l'absence de route, pas seulement sur un pare-feu. L'hôte reste joignable depuis les VM (il fournit le DHCP), ce qui est documenté comme limite assumée plutôt que comme faille.
- **Periphériques adaptés à chaque VM** : IDE/e1000 pour Metasploitable2 (ancien noyau), virtio pour Kali et cloudinit-demo (systèmes modernes).
- **Ressources ajustées** aux contraintes matérielles disponibles (VM hôte avec RAM limitée) : mémoire réduite sur les VM secondaires, VM allumées une à la fois quand nécessaire.

## Arborescence du dépôt
