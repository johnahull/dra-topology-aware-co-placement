import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("dra-verify.sh")


class DeviceClassVerifierTest(unittest.TestCase):
    def test_grouping_status_reflects_expanded_claim_allocation(self):
        deviceclasses = {
            "items": [
                self._grouping_class("storage-network-passthrough"),
                self._grouping_class("storage-network-passthrough-numa0", "numa0"),
            ]
        }
        resourceslices = {
            "items": [
                {
                    "spec": {
                        "driver": "dra.nvme",
                        "devices": [
                            {
                                "name": "nvme2",
                                "attributes": {
                                    "resource.kubernetes.io/numaNode": {"int": 0}
                                },
                            }
                        ],
                    }
                },
                {
                    "spec": {
                        "driver": "sriovnetwork.k8snetworkplumbingwg.io",
                        "devices": [
                            {
                                "name": "0000-89-01-2",
                                "attributes": {
                                    "resource.kubernetes.io/numaNode": {"int": 0}
                                },
                            }
                        ],
                    }
                },
            ]
        }
        claims = {
            "items": [
                {
                    "status": {
                        "reservedFor": [{"name": "virt-launcher-test"}],
                        "allocation": {
                            "devices": {
                                "results": [
                                    {
                                        "driver": "dra.nvme",
                                        "device": "nvme2",
                                    },
                                    {
                                        "driver": "sriovnetwork.k8snetworkplumbingwg.io",
                                        "device": "0000-89-01-2",
                                    },
                                ]
                            }
                        },
                    },
                    "spec": {
                        "devices": {
                            "requests": [
                                {"exactly": {"deviceClassName": "dra.nvme-vfio"}},
                                {
                                    "exactly": {
                                        "deviceClassName": "sriovnetwork.k8snetworkplumbingwg.io"
                                    }
                                },
                            ]
                        }
                    },
                }
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            for name, data in (
                ("deviceclasses.json", deviceclasses),
                ("resourceslices.json", resourceslices),
                ("resourceclaims.json", claims),
            ):
                (temp / name).write_text(json.dumps(data), encoding="utf-8")

            kubectl = temp / "kubectl"
            kubectl.write_text(
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  *deviceclasses*) cat \"$FAKE_DATA/deviceclasses.json\" ;;\n"
                "  *resourceslices*) cat \"$FAKE_DATA/resourceslices.json\" ;;\n"
                "  *resourceclaims*) cat \"$FAKE_DATA/resourceclaims.json\" ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            kubectl.chmod(kubectl.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env["FAKE_DATA"] = temp_dir
            env["PATH"] = f"{temp_dir}:{env['PATH']}"
            result = subprocess.run(
                [str(SCRIPT), "deviceclasses"],
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.count("⚡ virt-launcher-test"), 2)
        self.assertIn("scheduler-placed instances):", result.stdout)

    @staticmethod
    def _grouping_class(name, numa=""):
        labels = {
            "nodepartition.dra.k8s.io/alignment": "numaNode",
            "nodepartition.dra.k8s.io/grouping": "storage-network-passthrough",
            "nodepartition.dra.k8s.io/managed": "true",
        }
        if numa:
            labels["nodepartition.dra.k8s.io/numa"] = numa
        return {
            "metadata": {"name": name, "labels": labels},
            "spec": {
                "config": [
                    {
                        "opaque": {
                            "parameters": {
                                "kind": "PartitionConfig",
                                "subResources": [
                                    {"deviceClass": "dra.nvme-vfio", "count": 1},
                                    {
                                        "deviceClass": "sriovnetwork.k8snetworkplumbingwg.io",
                                        "count": 1,
                                    },
                                ],
                            }
                        }
                    }
                ]
            },
        }


if __name__ == "__main__":
    unittest.main()
