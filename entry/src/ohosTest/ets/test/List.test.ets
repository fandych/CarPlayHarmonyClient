import abilityTest from './Ability.test';
import settingsPersistenceDeviceTest from './SettingsPersistence.test';

export default function testsuite() {
  abilityTest();
  settingsPersistenceDeviceTest();
}