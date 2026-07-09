# [`cloudflared` tunneling](https://developers.cloudflare.com/tunnel/setup/)

`CLOUDFLARED_TOKEN` must be set under [Settings > Secrets and
variables > Actions > Repository
secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#creating-secrets-for-a-repository).

# SSH config

```ssh
Host example.org
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand cloudflared access ssh --hostname %h
```

# Local TCP bridge

```sh
$ cloudflared access tcp --hostname example.org --url 127.0.0.1:8388
````
