using Vector.Services;

namespace Vector.Engines {

    // json-glib builder boilerplate is obnoxious as hell, this just chains member+begin calls
    public class JsonSink {

        private Json.Builder b = new Json.Builder ();

        public JsonSink obj (string name = "") {
            if (name != "") b.set_member_name (name);
            b.begin_object ();
            return this;
        }

        public JsonSink end_obj () {
            b.end_object ();
            return this;
        }

        public JsonSink begin_arr () {
            b.begin_array ();
            return this;
        }

        public JsonSink arr (string name = "") {
            if (name != "") b.set_member_name (name);
            b.begin_array ();
            return this;
        }

        public JsonSink end_arr () {
            b.end_array ();
            return this;
        }

        public JsonSink member (string name) {
            b.set_member_name (name);
            return this;
        }

        public JsonSink str (string name, string value) {
            b.set_member_name (name);
            b.add_string_value (value);
            return this;
        }

        public JsonSink num (string name, int64 value) {
            b.set_member_name (name);
            b.add_int_value (value);
            return this;
        }

        public JsonSink flag (string name, bool value) {
            b.set_member_name (name);
            b.add_boolean_value (value);
            return this;
        }

        public JsonSink strs (string name, string[] values) {
            b.set_member_name (name);
            b.begin_array ();
            foreach (var v in values) b.add_string_value (v);
            b.end_array ();
            return this;
        }

        public JsonSink value_str (string value) {
            b.add_string_value (value);
            return this;
        }

        public JsonSink value_num (int64 value) {
            b.add_int_value (value);
            return this;
        }

        public JsonSink value_bool (bool value) {
            b.add_boolean_value (value);
            return this;
        }

        public string finish () {
            return Util.to_json_string (b);
        }
    }
}
