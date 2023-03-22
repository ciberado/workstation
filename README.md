# Workstation

Workstation is a project to provide a shared environment oriented to facilitate group-based remote learning. It achieves it by setting up an EC2 instance with software pre-installed and provide a way to use it together just by sharing an URL.

The URL starts with an automatically configured domain based with the form
`https://<owner>-workstation.aprender.cloud`, in which `<owner>` is configured
with a different value for each instance.

The packages installed include:

* A **Firefox** browser, accessible through VNC using the path `/firefox` after the machine domain name. Several users can share the same browser session, and the performance seems good.
* A **VSCode**-like environment based on [code-server](https://github.com/coder/code-server). The real-time sharing experience is quite good, taking only one or two seconds until all the viewers can see the files edited with the last modifications. The path for this service is `/vscode/`, and the default password is `supersecret`.
* A **ttyd** terminal with a bash prompt. It is an extremely effient way of sharing a session in real-time, as it uses `tmux` for multiplexing the terminal session. It is accessible through the path `/vscode/proxy/7681`.

Both **VSCode** and **ttyd** are in fact connected to the same terminal, and every application deployed on it will be accessible (after authentication) using the path pattern `/vscode/proxy/<port>`.

The terminal have several tools already available:

* `git`
* `terraform`
* `aws CLI`
* `node`, `npx` and `npm` (using [nvm](https://github.com/nvm-sh/nvm))
* `kubectl`
* `jq` and `yq`

The instance can be stopped and restarted safely. An *elastic IP* is attached to avoid the need of updating the DNS to a new IP.

## Instance deployment

Install terraform if necessary. Here there are the **ubuntu** instructions. For other OS, refer to the [Install Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli) web page.

```bash
apt install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com jammy main" -y
apt update 
apt install terraform -y
```

From a terminal in which `terraform` is already available with proper access to AWS:

```bash
git clone https://github.com/ciberado/workstation
cd workstation/src
terraform init
terraform apply -var owner=<name-of-the-owner>
```

## Cleanup

From the same directory in which the previous instructions were typed, run the next command:

```bash
terraform destroy
```
