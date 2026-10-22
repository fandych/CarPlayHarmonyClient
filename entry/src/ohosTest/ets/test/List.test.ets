import abilityTest from './Ability.test';
import iap2DiagnosticTest from './Iap2Diagnostic.test';
import settingsPersistenceDeviceTest from './SettingsPersistence.test';

export default function testsuite() {
  abilityTest();
  iap2DiagnosticTest();
  settingsPersistenceDeviceTest();
}