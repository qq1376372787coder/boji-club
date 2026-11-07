from pathlib import Path
import plistlib,re,unittest,xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]

class TestFlightConfigurationTests(unittest.TestCase):
    def test_all_signing_targets_and_configurations_use_supplied_team(self):
        source=(ROOT/'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8')
        blocks=re.findall(r'isa = XCBuildConfiguration; buildSettings = \{(.*?)\}; name = (Debug|Release|TestFlight);',source,re.S)
        signed=[(body,name) for body,name in blocks if 'CODE_SIGN_STYLE' in body]
        # app, widget, UI test and unit test target: Debug + Release/TestFlight
        self.assertEqual(len(signed),11)
        self.assertTrue(all('DEVELOPMENT_TEAM = GYFUN6MZ9J;' in body for body,_ in signed))

    def test_archive_scheme_is_optimized_and_excludes_debug(self):
        scheme=ET.parse(ROOT/'BojiClub.xcodeproj/xcshareddata/xcschemes/BojiClub-TestFlight.xcscheme')
        self.assertEqual(scheme.find('ArchiveAction').get('buildConfiguration'),'TestFlight')
        source=(ROOT/'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8')
        block=re.search(r'006100 = \{ isa = XCBuildConfiguration;.*?name = TestFlight;',source,re.S).group()
        self.assertIn('SWIFT_OPTIMIZATION_LEVEL = "-O"',block)
        self.assertIn('"BOJI_TESTFLIGHT $(inherited)"',block)
        self.assertNotIn('DEBUG $',block)

    def test_no_test_store_key_in_archived_configuration(self):
        source=(ROOT/'BojiClub.xcodeproj/project.pbxproj').read_text('utf-8')
        for body,name in re.findall(r'isa = XCBuildConfiguration; buildSettings = \{(.*?)\}; name = (Debug|Release|TestFlight);',source,re.S):
            if name=='Debug':continue
            key=re.search(r'REVENUECAT_PUBLIC_SDK_KEY = "([^"]*)"',body)
            if 'CODE_SIGN_ENTITLEMENTS = BojiClub/BojiClub.entitlements;' in body:
                self.assertIsNotNone(key,name)
                self.assertTrue(key.group(1).startswith('appl_'),name)

    def test_exact_product_ids_and_entitlement(self):
        value=plistlib.loads((ROOT/'BojiClub/Info.plist').read_bytes())
        self.assertEqual(value['RevenueCatMonthlyProductID'],'yuefu')
        self.assertEqual(value['RevenueCatAnnualProductID'],'nianfu')
        self.assertEqual(value['RevenueCatLifetimeProductID'],'yongjiu')
        self.assertEqual(value['RevenueCatMemberEntitlementID'],'薄肌俱乐部_pro')
        self.assertNotIn('RevenueCatSixMonthProductID',value)

    def test_preview_does_not_call_purchase_and_prices_remain_dynamic(self):
        source=(ROOT/'BojiClub/RevenueCatViews.swift').read_text('utf-8')
        self.assertIn('if isPricePreview { previewNotice = true }',source)
        self.assertIn('else { membership.purchase(selectedPlan) }',source)
        self.assertIn('return membership.price(for: plan)',source)
        self.assertIn('if !isPricePreview { membership.refresh(force: true) }',source)
        self.assertRegex(source,r'#if DEBUG\s+private var screenshotPreview')

    def test_all_three_plan_options_and_renewal_copy(self):
        source=(ROOT/'BojiClub/MembershipService.swift').read_text('utf-8')
        self.assertIn('case monthly, annual, lifetime',source)
        self.assertIn('offering.annual',source)
        self.assertNotIn('case .sixMonth',source)
        self.assertIn('每年自动续订',source)
        self.assertIn('一次购买，不自动续订',source)

if __name__=='__main__':unittest.main()
