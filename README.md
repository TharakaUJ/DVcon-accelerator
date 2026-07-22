# DVCon Accelerator

FPGA-based YOLO Winograd accelerator research and RTL prototype.

## Project Links

- Model repository: [Main model (software approach)](https://github.com/BimsaraU/DVCon-SittingDucks)
- Relevant project links:
  - [K-graph approach](https://github.com/thilakshan2003/DVCON-kgraph_for_coco)

## How to setup the project with IP

- place the ip in the root of the folder.
- run `make init` or `make reinit` to initialize or reinitialize the project.
- The ip zip, youll have to place manually since it is a proprietery IP.
- To update any changes that needed to be done in project at initilalizing, follow the following steps. The patches are applied when `make init` or `make reinit`.

### Creating patches
copy the file need to be patched and make the needed diffs.
then run,
```bash
git diff --no-index /path/to/foo /path/to/bar >> patches/patch_name.patch
```
check the generated patch file and remove any unwanted lines. Then commit the patch file to the repo.