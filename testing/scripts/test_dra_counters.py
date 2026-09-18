#!/usr/bin/env python3
import io
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("dra-counters.py")
SPEC = importlib.util.spec_from_file_location("dra_counters", MODULE_PATH)
COUNTERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COUNTERS)


def device(name, pci, consumes=None, is_vf=True):
    result = {
        "name": name,
        "attributes": {
            "resource.kubernetes.io/pciBusID": {"string": pci},
            "isVF": {"bool": is_vf},
        },
    }
    if consumes:
        result["consumesCounters"] = [{
            "counterSet": "pf-0",
            "counters": {"vf-slots": {"value": "1"}},
        }]
    return result


def slices(devices):
    return {"items": [{
        "spec": {
            "driver": "gpu.amd.com", "pool": {"name": "node-a"},
            "sharedCounters": [{
                "name": "pf-0", "counters": {"vf-slots": {"value": "2"}},
            }],
            "devices": devices,
        },
    }]}


def claims(results, reserved=None):
    results = [
        {**result, "pool": result.get("pool", "node-a")}
        for result in results
    ]
    return {"items": [{
        "metadata": {"namespace": "default", "name": "claim-a"},
        "status": {
            "reservedFor": reserved or [{"namespace": "default", "name": "pod-a"}],
            "allocation": {"devices": {"results": results}},
        },
    }]}


class CounterReportTest(unittest.TestCase):
    def render(self, slice_data, claim_data):
        output = io.StringIO()
        COUNTERS.render(slice_data, claim_data, output)
        return output.getvalue()

    def test_direct_allocation_is_subtracted(self):
        output = self.render(
            slices([device("vf-0", "0000:01:00.0", consumes=True)]),
            claims([{"driver": "gpu.amd.com", "device": "vf-0"}]),
        )
        self.assertIn("1/2", output)
        self.assertIn("pod-a", output)
        self.assertNotIn("available", output)

    def test_compute_device_correlates_to_vfio_sibling_by_pci(self):
        output = self.render(
            slices([
                device("gpu-0", "0000:01:00.0", consumes=False, is_vf=False),
                device("gpu-vfio-0", "0000:01:00.0", consumes=True),
            ]),
            claims([{"driver": "gpu.amd.com", "device": "gpu-0"}]),
        )
        self.assertIn("1/2", output)
        self.assertIn("PCI identity", output)

    def test_direct_allocation_is_not_mislabeled_as_pci_correlation(self):
        output = self.render(
            slices([
                device("gpu-vfio-0", "0000:01:00.0", consumes=True),
                device("gpu-vfio-1", "0000:02:00.0", consumes=True),
            ]),
            claims([
                {"driver": "gpu.amd.com", "device": "gpu-vfio-1"},
                {"driver": "gpu.amd.com", "device": "gpu-vfio-0"},
            ]),
        )
        direct_line = next(
            line for line in output.splitlines() if "gpu-vfio-1" in line
        )
        self.assertNotIn("PCI identity", direct_line)

    def test_allocation_pool_is_part_of_device_identity(self):
        output = self.render(
            {
                "items": [
                    {
                        "spec": {
                            "driver": "gpu.amd.com",
                            "pool": {"name": "node-a"},
                            "sharedCounters": [{
                                "name": "pf-0",
                                "counters": {"vf-slots": {"value": "1"}},
                            }],
                            "devices": [device("vf-0", "0000:01:00.0", consumes=True)],
                        },
                    },
                    {
                        "spec": {
                            "driver": "gpu.amd.com",
                            "pool": {"name": "node-b"},
                            "sharedCounters": [{
                                "name": "pf-0",
                                "counters": {"vf-slots": {"value": "1"}},
                            }],
                            "devices": [device("vf-0", "0000:02:00.0", consumes=True)],
                        },
                    },
                ],
            },
            claims([{
                "driver": "gpu.amd.com",
                "pool": "node-b",
                "device": "vf-0",
            }]),
        )
        node_a_section, node_b_section = output.split("(pool: node-b)")
        node_b_section = "(pool: node-b)" + node_b_section
        node_a_line = next(line for line in node_a_section.splitlines() if "1/1" in line)
        node_b_line = next(line for line in node_b_section.splitlines() if "0/1" in line)
        self.assertIn("1/1", node_a_line)
        self.assertIn("0/1", node_b_line)

    def test_missing_allocated_device_is_not_reported_free(self):
        output = self.render(
            slices([device("gpu-vfio-0", "0000:01:00.0", consumes=True)]),
            claims([{"driver": "gpu.amd.com", "device": "gpu-removed"}]),
        )
        self.assertIn("?", output)
        self.assertIn("/2", output)
        self.assertIn("Stale allocation results", output)
        self.assertIn("claim default/claim-a", output)
        self.assertIn("absent from current ResourceSlices", output)
        self.assertIn("allocation correlation incomplete", output)

        output_stream = io.StringIO()
        status = COUNTERS.render(
            slices([device("gpu-vfio-0", "0000:01:00.0", consumes=True)]),
            claims([{"driver": "gpu.amd.com", "device": "gpu-removed"}]),
            output_stream,
        )
        self.assertEqual(2, status)

    def test_multiple_reserved_consumers_are_visible(self):
        output = self.render(
            slices([device("vf-0", "0000:01:00.0", consumes=True)]),
            claims(
                [{"driver": "gpu.amd.com", "device": "vf-0"}],
                [{"namespace": "default", "name": "pod-a"}, {"namespace": "default", "name": "pod-b"}],
            ),
        )
        self.assertIn("default/pod-a,default/pod-b", output)

    def test_invalid_counter_reference_is_diagnostic(self):
        data = slices([device("vf-0", "0000:01:00.0", consumes=True)])
        data["items"][0]["spec"]["devices"][0]["consumesCounters"][0]["counterSet"] = "missing"
        output = self.render(data, {"items": []})
        self.assertIn("references missing counter set missing", output)

        output_stream = io.StringIO()
        status = COUNTERS.render(data, {"items": []}, output_stream)
        self.assertEqual(1, status)


if __name__ == "__main__":
    unittest.main()
