# Deliberately unsafe pattern. Used only by
# .github/workflows/test-security-scan.yml to prove Semgrep still flags a
# known rule (subprocess call with shell=True) after a version/ruleset
# bump. Never executed.


def run(cmd: str) -> None:
    import subprocess

    subprocess.run(cmd, shell=True)
