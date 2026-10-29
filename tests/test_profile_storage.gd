extends TestCase
## Encrypted profile storage: round trip, backup recovery, wrong key,
## migrations, duplicate detection, profile manager operations.

const PATH := "user://test_profiles_storage.dat"
const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"


func _key(seed: int) -> PackedByteArray:
	var k := PackedByteArray()
	k.resize(32)
	for i in 32:
		k[i] = (i * 7 + seed) % 256
	return k


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(PATH + suffix):
			DirAccess.remove_absolute(PATH + suffix)


func _sample() -> Array:
	var a: ProfileModel = LinkParser.parse("vless://%s@a.example.com:443?security=reality&sni=x.com&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0#Кириллица ✓" % UUID).profile
	var b: ProfileModel = LinkParser.parse("trojan://pw@b.example.com:443#B").profile
	b.favorite = true
	b.extra["unknown_future_field"] = {"x": 1}
	return [a, b]


func test_round_trip_encrypted() -> void:
	_clean()
	var st := ProfileStorage.new(PATH, _key(1))
	var subs := [{"id": "s1", "url": "https://x/sub?token=SECRET", "name": "S"}]
	eq(st.save_all(_sample(), subs), OK)
	var raw := FileAccess.get_file_as_bytes(PATH).get_string_from_ascii()
	check(not raw.contains(UUID) and not raw.contains("SECRET"), "file must not contain plaintext secrets")
	var r := ProfileStorage.new(PATH, _key(1)).load_all()
	if not ok_result(r):
		return
	eq(r.profiles.size(), 2)
	eq(r.profiles[0].name, "Кириллица ✓")
	eq(r.profiles[0].outbound.uuid, UUID)
	eq(r.profiles[0].outbound.server_port, 443)
	eq(typeof(r.profiles[0].outbound.server_port), TYPE_INT, "ints stay ints after JSON round trip")
	eq(r.profiles[1].favorite, true)
	eq(r.profiles[1].extra.unknown_future_field, {"x": 1}, "unknown fields preserved")
	eq(r.subscriptions[0].url, "https://x/sub?token=SECRET")
	_clean()


func test_wrong_key_fails_without_damage() -> void:
	_clean()
	ProfileStorage.new(PATH, _key(1)).save_all(_sample(), [])
	var before := FileAccess.get_file_as_bytes(PATH)
	var r := ProfileStorage.new(PATH, _key(2)).load_all()
	err_result(r)
	eq(FileAccess.get_file_as_bytes(PATH), before, "file untouched")
	_clean()


func test_corrupted_file_recovers_from_backup() -> void:
	_clean()
	var st := ProfileStorage.new(PATH, _key(3))
	st.save_all(_sample(), [])
	st.save_all(_sample().slice(0, 1), []) # second save creates .bak of the first
	var f := FileAccess.open(PATH, FileAccess.READ_WRITE)
	f.seek(40)
	f.store_buffer(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
	f.close()
	var r := st.load_all()
	if ok_result(r, "recovered"):
		eq(r.recovered, true)
		eq(r.profiles.size(), 2, "backup holds the previous version")
	_clean()


func test_truncated_and_missing() -> void:
	_clean()
	var st := ProfileStorage.new(PATH, _key(4))
	var empty := st.load_all()
	if ok_result(empty, "missing file = empty db"):
		eq(empty.profiles.size(), 0)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	err_result(st.load_all())
	_clean()


func test_migration_v1() -> void:
	var data := {"_schema": 1, "profiles": [{"id": "x", "name": "old", "protocol": "trojan", "latency_ms": 120}]}
	var m := ProfileStorage.migrate(data)
	eq(int(m._schema), ProfileStorage.SCHEMA_VERSION)
	var p := ProfileModel.from_dict(m.profiles[0])
	eq(int(p.latency.ms), 120)
	eq(p.latency.status, ProfileModel.LAT_OK)


func test_manager_crud_and_duplicates() -> void:
	var settings_backup := Settings.export_data()
	Profiles.storage_path = "user://test_profiles_mgr.dat"
	for s in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(Profiles.storage_path + s):
			DirAccess.remove_absolute(Profiles.storage_path + s)
	Profiles.load_from_disk()
	var res := Profiles.import_text("vless://%s@a.example.com:443#A\nvless://%s@a.example.com:443#A-dup\ntrojan://pw@b.example.com:443#B" % [UUID, UUID], "clipboard")
	if not ok_result(res):
		return
	eq(res.added.size(), 2)
	eq(res.duplicates, 1)
	var again := Profiles.import_text("trojan://pw@b.example.com:443#B again", "clipboard")
	eq(again.added.size(), 0, "duplicate of existing profile rejected")
	var a_id: String = res.added[0]
	eq(Profiles.rename(a_id, "  Новое имя "), "")
	eq(Profiles.get_profile(a_id).name, "Новое имя")
	check(Profiles.rename(a_id, "   ") != "", "empty name rejected")
	var copy := Profiles.duplicate_profile(a_id)
	check(copy != null and copy.id != a_id, "duplicate created")
	Profiles.move(copy.id, -10)
	eq(Profiles.get_all()[0].id, copy.id, "moved to top")
	Profiles.set_favorite(a_id, true)
	eq(Profiles.query("", "favorites").size(), 1)
	eq(Profiles.query("НОВОЕ").size(), 2, "search is case-insensitive (original + copy)")
	Profiles.set_active(a_id)
	Profiles.remove(a_id)
	eq(Profiles.get_active(), null, "active cleared when removed")
	Profiles.save_now()
	Profiles.load_from_disk()
	eq(Profiles.count(), 2, "persisted")
	var backup := Profiles.export_backup()
	Profiles.reset_storage()
	eq(Profiles.count(), 0)
	var rb := Profiles.import_backup(backup, false)
	if ok_result(rb):
		eq(rb.profiles, 2)
	Profiles.reset_storage()
	Profiles.storage_path = ProfileStorage.DEFAULT_PATH
	Profiles.load_from_disk()
	Settings.import_data(settings_backup)
