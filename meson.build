project('vector', ['c', 'vala'],
  version: '0.1.0',
  license: 'GPL-3.0-only',
  meson_version: '>= 0.62')

add_project_arguments(['--target-glib=2.74', '--enable-experimental',
  '--vapidir', meson.current_source_dir() / 'src' / 'vapi'], language: 'vala')

if get_option('gcc_warnings')
  add_project_arguments([
    '-Wno-unused-but-set-variable', '-Wno-unused-variable', '-Wno-unused-function',
    '-Wno-unused-label', '-Wno-discarded-qualifiers', '-Wno-address',
  ], language: 'c')
else
  add_project_arguments('-w', language: 'c')
endif

deps = [
  dependency('glib-2.0', version: '>= 2.74'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4', version: '>= 4.18'),
  dependency('libadwaita-1', version: '>= 1.7'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('libqrencode'),
  meson.get_compiler('vala').find_library('posix'),
]

conf = configuration_data()
conf.set('APP_VERSION', meson.project_version())
conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir') / 'vector')

python = find_program('python3')
core_versions = run_command(python, files('fetch_cores.py'), '--print-versions',
  check: true).stdout().strip().split('\n')
conf.set('SING_BOX_VERSION', core_versions[0])
conf.set('XRAY_VERSION', core_versions[1])
conf.set('SING_BOX_LX_VERSION', core_versions[2])

build_vala = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: conf)

if get_option('fetch_cores')
  custom_target('proxy-cores',
    output: ['xray', 'sing-box', 'sing-box-lx'],
    command: [python, files('fetch_cores.py'), '@OUTDIR@'],
    build_by_default: true,
    install: true,
    install_dir: get_option('libexecdir') / 'vector')
endif

gnome = import('gnome')
resources = gnome.compile_resources('vector-resources',
  'data/io.github.dp0sk.Vector.gresource.xml',
  source_dir: 'data',
  c_name: 'vector_resources')

vector_exe = executable('vector-adw',
  [
    build_vala,
    resources,

    'src/models/WgConfig.vala',
    'src/models/Node.vala',
    'src/models/AppSettings.vala',
    'src/models/Store.vala',

    'src/routing/RoutingRule.vala',
    'src/routing/RoutingPreset.vala',
    'src/routing/RoutingRulesFetcher.vala',

    'src/subscriptions/SubGroup.vala',
    'src/subscriptions/SubscriptionManager.vala',
    'src/subscriptions/HappLink.vala',

    'src/engines/Cores.vala',
    'src/engines/UserUnit.vala',
    'src/engines/SessionRouter.vala',
    'src/engines/SystemdInstaller.vala',
    'src/engines/CoreRunner.vala',
    'src/engines/config/JsonSink.vala',
    'src/engines/config/ConfigGenerator.vala',
    'src/engines/config/SingBoxConfig.vala',
    'src/engines/config/XrayConfig.vala',

    'src/services/Paths.vala',
    'src/services/Util.vala',
    'src/services/SystemProxy.vala',
    'src/services/HttpClient.vala',
    'src/services/LogFormatter.vala',
    'src/services/GeoManager.vala',
    'src/services/TrayIcon.vala',

    'src/testing/Tester.vala',
    'src/testing/Benchmarker.vala',

    'src/ui/NodeRow.vala',
    'src/ui/MatchWidthBin.vala',
    'src/ui/PresetEntryRow.vala',
    'src/ui/RoutingDialog.vala',
    'src/ui/NodeEditDialog.vala',
    'src/ui/GroupEditDialog.vala',
    'src/ui/DialogHeader.vala',
    'src/ui/QrCode.vala',
    'src/ui/Clipboard.vala',
    'src/ui/Widgets.vala',

    'src/Window.vala',
    'src/window/ConnectFlow.vala',
    'src/window/ConnectionStatus.vala',
    'src/window/SystemProxyTray.vala',

    'src/pages/servers/ServersPage.vala',
    'src/pages/servers/ServersNodes.vala',
    'src/pages/servers/ServersTests.vala',
    'src/pages/servers/ServersSorting.vala',
    'src/pages/SubsPage.vala',
    'src/pages/RoutePage.vala',
    'src/pages/CorePage.vala',
    'src/pages/ServicePage.vala',
    'src/pages/LogPage.vala',

    'src/Application.vala',
  ],
  dependencies: deps,
  install: true)

logic_deps = [
  dependency('glib-2.0', version: '>= 2.74'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('json-glib-1.0'),
  dependency('libsoup-3.0'),
  dependency('gtk4', version: '>= 4.18'),
  meson.get_compiler('vala').find_library('posix'),
]

logic_test_sources = files(
  'src/models/WgConfig.vala',
  'tests/LogicTests.vala',
  'src/models/Node.vala',
  'src/models/AppSettings.vala',
  'src/models/Store.vala',
  'src/routing/RoutingRule.vala',
  'src/routing/RoutingPreset.vala',
  'src/subscriptions/SubGroup.vala',
  'src/subscriptions/SubscriptionManager.vala',
  'src/subscriptions/HappLink.vala',
  'src/engines/Cores.vala',
  'src/engines/config/JsonSink.vala',
  'src/engines/config/ConfigGenerator.vala',
  'src/engines/config/SingBoxConfig.vala',
  'src/engines/config/XrayConfig.vala',
  'src/services/Paths.vala',
  'src/services/Util.vala',
  'src/services/HttpClient.vala',
  'src/services/LogFormatter.vala',
) + build_vala

logic_test = executable('vector-logic-tests', logic_test_sources, resources, dependencies: logic_deps,
  install: false)
test('logic', logic_test)

install_data('data/io.github.dp0sk.Vector.desktop',
  install_dir: get_option('datadir') / 'applications')
install_data('data/icons/hicolor/scalable/apps/io.github.dp0sk.Vector.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps')
install_data('data/icons/hicolor/symbolic/apps/io.github.dp0sk.Vector-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps')
install_data('data/io.github.dp0sk.Vector.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo')
