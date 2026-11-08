#!/usr/bin/env python3
"""Verify both naming modes against the patched BlackHole source, without installing it."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = root / '.build/buddy-driver/BlackHole/BlackHole/BlackHole.c'
if not source.is_file():
    raise SystemExit('Run scripts/build-driver.sh first.')

with tempfile.TemporaryDirectory(prefix='buddy-driver-identity-') as directory:
    work = Path(directory)
    # Include the real source so its private getters are exercised, rather than copied.
    harness = work / 'identity.c'
    harness.write_text('''#include <assert.h>
#include "BlackHole.c"
static void expect(CFStringRef actual, CFStringRef expected) {
    assert(actual != NULL);
    assert(CFEqual(actual, expected));
    CFRelease(actual);
}
int main(void) {
    expect(get_box_uid(), CFSTR("BuddyMic2ch_UID"));
    expect(get_device_uid(), CFSTR("BuddyMic2ch_UID"));
    expect(get_device2_uid(), CFSTR("BuddyMic2ch_2_UID"));
    expect(get_device_model_uid(), CFSTR("BuddyMic2ch_ModelUID"));
#if kHas_Driver_Name_Format
    expect(get_device_name(), CFSTR("BuddyMic 2ch"));
    expect(get_device2_name(), CFSTR("BuddyMic 2ch 2"));
#else
    expect(get_device_name(), CFSTR("Remote Buddy Mic"));
    expect(get_device2_name(), CFSTR("BuddyMic2ch Mirror"));
#endif
    return 0;
}
''')
    for formatted in (0, 1):
        executable = work / f'identity-{formatted}'
        flags = [f'-DkHas_Driver_Name_Format={formatted}', '-DkNumber_Of_Channels=2']
        if formatted:
            flags += ['-DkDriver_Name="BuddyMic"']
        else:
            flags += ['-DkDriver_Name="BuddyMic2ch"', '-DkDevice_Name="Remote Buddy Mic"']
        subprocess.run([
            'xcrun', 'clang', '-O2', '-Werror=format-extra-args',
            '-I', str(source.parent), *flags, str(harness), '-o', str(executable),
            '-framework', 'CoreFoundation', '-framework', 'CoreAudio',
            '-framework', 'Accelerate',
        ], check=True)
        subprocess.run([str(executable)], check=True)
print('Driver naming checks passed: fixed and channel-formatted names/UIDs.')
