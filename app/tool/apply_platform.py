import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLATFORM = os.path.join(ROOT, 'platform')
APPLICATION_ID = 'com.velo.app'
MIN_SDK = 24


def log(message):
    print('[apply-platform] %s' % message)


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)


def android():
    app_dir = os.path.join(ROOT, 'android', 'app')
    if not os.path.isdir(app_dir):
        log('android project missing, skipping')
        return

    main_dir = os.path.join(app_dir, 'src', 'main')
    for language in ('kotlin', 'java'):
        target = os.path.join(main_dir, language)
        if os.path.isdir(target):
            shutil.rmtree(target)

    source = os.path.join(PLATFORM, 'android', 'kotlin')
    destination = os.path.join(main_dir, 'kotlin')
    shutil.copytree(source, destination)
    log('kotlin sources installed')

    shutil.copyfile(
        os.path.join(PLATFORM, 'android', 'AndroidManifest.xml'),
        os.path.join(main_dir, 'AndroidManifest.xml'),
    )
    log('manifest installed')

    res_overlay = os.path.join(PLATFORM, 'android', 'res')
    if os.path.isdir(res_overlay):
        shutil.copytree(
            res_overlay,
            os.path.join(main_dir, 'res'),
            dirs_exist_ok=True,
        )
        log('resources merged')

    libs = os.path.join(app_dir, 'libs')
    os.makedirs(libs, exist_ok=True)
    keep = os.path.join(libs, '.gitkeep')
    if not os.path.exists(keep):
        write(keep, '')

    kts = os.path.join(app_dir, 'build.gradle.kts')
    groovy = os.path.join(app_dir, 'build.gradle')
    if os.path.exists(kts):
        patch_gradle_kts(kts)
    elif os.path.exists(groovy):
        patch_gradle_groovy(groovy)
    else:
        log('no app build script found')


def patch_gradle_kts(path):
    text = read(path)
    if 'velo platform overlay' in text:
        log('build.gradle.kts already patched')
        return

    text = re.sub(
        r'namespace\s*=\s*"[^"]*"',
        'namespace = "%s"' % APPLICATION_ID,
        text,
    )
    text = re.sub(
        r'applicationId\s*=\s*"[^"]*"',
        'applicationId = "%s"' % APPLICATION_ID,
        text,
    )
    text += '''
// velo platform overlay
android {
    defaultConfig {
        minSdk = %d
    }
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
}
''' % MIN_SDK
    write(path, text)
    log('build.gradle.kts patched')


def patch_gradle_groovy(path):
    text = read(path)
    if 'velo platform overlay' in text:
        log('build.gradle already patched')
        return

    text = re.sub(r"namespace\s+'[^']*'", "namespace '%s'" % APPLICATION_ID, text)
    text = re.sub(r'namespace\s+"[^"]*"', 'namespace "%s"' % APPLICATION_ID, text)
    text = re.sub(
        r"applicationId\s+\"?'?[^\"'\n]*\"?'?",
        'applicationId "%s"' % APPLICATION_ID,
        text,
        count=1,
    )
    text += '''
// velo platform overlay
android {
    defaultConfig {
        minSdkVersion %d
    }
    packagingOptions {
        jniLibs {
            useLegacyPackaging true
        }
    }
}

dependencies {
    implementation fileTree(dir: 'libs', include: ['*.aar'])
}
''' % MIN_SDK
    write(path, text)
    log('build.gradle patched')


def macos():
    runner = os.path.join(ROOT, 'macos', 'Runner')
    if not os.path.isdir(runner):
        log('macos project missing, skipping')
        return

    for name in ('DebugProfile.entitlements', 'Release.entitlements'):
        shutil.copyfile(
            os.path.join(PLATFORM, 'macos', name),
            os.path.join(runner, name),
        )
    log('entitlements installed')

    config = os.path.join(runner, 'Configs', 'AppInfo.xcconfig')
    if os.path.exists(config):
        text = read(config)
        text = re.sub(r'PRODUCT_NAME\s*=.*', 'PRODUCT_NAME = Velo', text)
        text = re.sub(
            r'PRODUCT_BUNDLE_IDENTIFIER\s*=.*',
            'PRODUCT_BUNDLE_IDENTIFIER = %s' % APPLICATION_ID,
            text,
        )
        text = re.sub(
            r'PRODUCT_COPYRIGHT\s*=.*',
            'PRODUCT_COPYRIGHT = Velo',
            text,
        )
        write(config, text)
        log('macos app info patched')


def windows():
    runner = os.path.join(ROOT, 'windows', 'runner')
    if not os.path.isdir(runner):
        log('windows project missing, skipping')
        return

    main_cpp = os.path.join(runner, 'main.cpp')
    if os.path.exists(main_cpp):
        text = read(main_cpp)
        text = text.replace('L"velo"', 'L"Velo"')
        write(main_cpp, text)
        log('windows window title patched')


def main(platforms):
    wanted = [item.strip() for item in platforms.split(',') if item.strip()]
    if 'android' in wanted:
        android()
    if 'macos' in wanted:
        macos()
    if 'windows' in wanted:
        windows()
    log('done')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'android,macos,windows'))
