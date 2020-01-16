# bindle

Build tool scripts.

> **bindle** bin·dle  
> noun  
> a stick with cloth or a blanket tied around one end for carrying items, carried over the shoulder

## Usage

Add as a submodule:

```sh
git submodule add git@github.com:jesims/bindle.git
git submodule init
```

Then in your own project bash file (e.g. `jesi.sh`):

```sh
source bindle/project.sh

#your functions here

script-invoke "$@"
```

See [bindle.sh](bindle.sh)
