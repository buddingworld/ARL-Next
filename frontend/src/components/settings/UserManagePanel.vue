<template>
  <div class="tab-content" style="padding: 20px;">
    <a-card data-setting-anchor="user_manage" :title="pageText('pages.userManagement')" :bordered="false" style="max-width: 1050px;">
      <div style="font-size: 13px; color: var(--arl-text-color); opacity: 0.65; line-height: 1.6; margin-bottom: 16px;">
        {{ pageText('pages.userManagementDescription') }}
      </div>

      <!-- 顶部操作栏 -->
      <div style="display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 16px;">
        <a-input-search
          v-model:value="keyword"
          :placeholder="pageText('pages.userSearchPlaceholder')"
          style="max-width: 280px;"
          allow-clear
          @search="fetchUsers"
        />
        <a-button type="primary" @click="openAddModal">
          <template #icon><UserAddOutlined /></template>
          {{ pageText('pages.userAdd') }}
        </a-button>
      </div>

      <a-table
        :data-source="users"
        :columns="columns"
        :loading="loading"
        row-key="username"
        size="middle"
        :pagination="false"
      >
        <template #bodyCell="{ column, record }">
          <template v-if="column.key === 'role'">
            <a-tag :color="record.role === 'admin' ? 'gold' : 'blue'">
              {{ record.role === 'admin' ? pageText('pages.userRoleAdmin') : pageText('pages.userRoleUser') }}
            </a-tag>
          </template>

          <template v-else-if="column.key === 'status'">
            <a-tag :color="record.status === 'locked' ? 'red' : 'green'">
              {{ record.status === 'locked' ? pageText('pages.userStatusLocked') : pageText('pages.userStatusActive') }}
            </a-tag>
          </template>

          <template v-else-if="column.key === 'last_login'">
            {{ record.last_login || pageText('pages.userNeverLogin') }}
          </template>

          <template v-else-if="column.key === 'action'">
            <a-space size="small">
              <a @click="openEditModal(record)">{{ pageText('pages.userEdit') }}</a>

              <a-tooltip :title="record.username === currentUsername ? pageText('pages.userSelfOperationForbidden') : ''">
                <a
                  :class="{ 'user-action-disabled': record.username === currentUsername }"
                  @click="record.username !== currentUsername && handleToggleLock(record)"
                >
                  {{ record.status === 'locked' ? pageText('pages.userUnlock') : pageText('pages.userLock') }}
                </a>
              </a-tooltip>

              <a-tooltip :title="record.username === currentUsername ? pageText('pages.userSelfOperationForbidden') : ''">
                <a
                  style="color: #ff4d4f;"
                  :class="{ 'user-action-disabled': record.username === currentUsername }"
                  @click="record.username !== currentUsername && handleDelete(record)"
                >
                  {{ pageText('pages.userDelete') }}
                </a>
              </a-tooltip>
            </a-space>
          </template>
        </template>
      </a-table>
    </a-card>

    <!-- 新增 / 编辑弹窗 -->
    <a-modal
      v-model:open="modalVisible"
      :title="isEdit ? pageText('pages.userEditTitle') : pageText('pages.userAddTitle')"
      :okText="pageText('pages.userSave')"
      :cancelText="pageText('pages.userCancel')"
      :confirmLoading="saving"
      @ok="handleSubmit"
    >
      <a-form :model="form" layout="vertical" style="margin-top: 16px;">
        <a-form-item :label="pageText('pages.userUsername')" required>
          <a-input
            v-model:value="form.username"
            :disabled="isEdit"
            :placeholder="pageText('pages.userUsernamePlaceholder')"
          />
        </a-form-item>

        <a-form-item
          :label="isEdit ? pageText('pages.userPasswordOptional') : pageText('pages.userPassword')"
          :required="!isEdit"
        >
          <a-input-password
            v-model:value="form.password"
            autocomplete="new-password"
            :placeholder="isEdit ? pageText('pages.userPasswordKeepHint') : pageText('pages.userPasswordPlaceholder')"
          />
        </a-form-item>

        <a-form-item :label="pageText('pages.userRole')">
          <a-select v-model:value="form.role" :disabled="isEdit && form.username === currentUsername">
            <a-select-option value="user">{{ pageText('pages.userRoleUser') }}</a-select-option>
            <a-select-option value="admin">{{ pageText('pages.userRoleAdmin') }}</a-select-option>
          </a-select>
          <div
            v-if="isEdit && form.username === currentUsername"
            style="font-size: 12px; opacity: 0.65; margin-top: 4px;"
          >
            {{ pageText('pages.userSelfOperationForbidden') }}
          </div>
        </a-form-item>
      </a-form>
    </a-modal>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { message, Modal } from 'ant-design-vue';
import { UserAddOutlined } from '@ant-design/icons-vue';
import request from '@/utils/request';

const { t: pageText } = useI18n({ useScope: 'global' });

// 当前登录账号：用于在界面上禁用「删除自己 / 锁定自己 / 改自己的角色」，
// 与后端的三条自我保护规则保持一致，避免用户点了才被拒绝
const currentUsername = ref('');
try {
  const userInfo = JSON.parse(localStorage.getItem('userInfo') || '{}');
  currentUsername.value = userInfo.username || '';
} catch (e) {
  currentUsername.value = '';
}

const users = ref([]);
const loading = ref(false);
const keyword = ref('');

const modalVisible = ref(false);
const saving = ref(false);
const isEdit = ref(false);
const form = reactive({
  username: '',
  password: '',
  role: 'user'
});

const columns = computed(() => [
  { title: pageText('pages.userUsername'), dataIndex: 'username', key: 'username' },
  { title: pageText('pages.userRole'), dataIndex: 'role', key: 'role', width: 110 },
  { title: pageText('pages.userStatus'), dataIndex: 'status', key: 'status', width: 110 },
  { title: pageText('pages.userCreateTime'), dataIndex: 'create_time', key: 'create_time', width: 180 },
  { title: pageText('pages.userLastLogin'), dataIndex: 'last_login', key: 'last_login', width: 180 },
  { title: pageText('pages.userAction'), key: 'action', width: 190 }
]);

const fetchUsers = async () => {
  loading.value = true;
  try {
    const res = await request.get('/user/list/', { params: { keyword: keyword.value || '' } });
    if (res.code === 200) {
      users.value = res.data || [];
    } else {
      message.error(res.message || pageText('pages.userFetchFailed'));
    }
  } catch (error) {
    console.error('获取用户列表异常:', error);
    message.error(pageText('pages.userFetchFailed'));
  } finally {
    loading.value = false;
  }
};

const resetForm = () => {
  form.username = '';
  form.password = '';
  form.role = 'user';
};

const openAddModal = () => {
  isEdit.value = false;
  resetForm();
  modalVisible.value = true;
};

const openEditModal = (record) => {
  isEdit.value = true;
  resetForm();
  form.username = record.username;
  form.role = record.role;
  modalVisible.value = true;
};

const handleSubmit = async () => {
  const username = (form.username || '').trim();
  if (!username) {
    message.warning(pageText('pages.userUsernameRequired'));
    return;
  }
  if (!isEdit.value && !form.password) {
    message.warning(pageText('pages.userPasswordRequired'));
    return;
  }

  saving.value = true;
  try {
    const url = isEdit.value ? '/user/update/' : '/user/add/';
    const payload = { username, role: form.role };
    // 编辑时留空表示不修改密码，不提交该字段
    if (form.password) {
      payload.password = form.password;
    }

    const res = await request.post(url, payload);
    if (res.code === 200) {
      message.success(pageText('pages.userSaveSuccess'));
      modalVisible.value = false;
      await fetchUsers();
    } else {
      message.error(res.message || pageText('pages.userOperationFailed'));
    }
  } catch (error) {
    console.error('保存用户异常:', error);
    message.error(pageText('pages.userOperationFailed'));
  } finally {
    saving.value = false;
  }
};

const handleDelete = (record) => {
  Modal.confirm({
    title: pageText('pages.userDeleteConfirmTitle'),
    content: pageText('pages.userDeleteConfirmContent').replace('{name}', record.username),
    okText: pageText('pages.userConfirm'),
    okType: 'danger',
    cancelText: pageText('pages.userCancel'),
    onOk: async () => {
      const res = await request.post('/user/delete/', { username: record.username });
      if (res.code === 200) {
        message.success(pageText('pages.userDeleteSuccess'));
        await fetchUsers();
      } else {
        message.error(res.message || pageText('pages.userOperationFailed'));
      }
    }
  });
};

const handleToggleLock = (record) => {
  const willLock = record.status !== 'locked';
  Modal.confirm({
    title: willLock ? pageText('pages.userLockConfirmTitle') : pageText('pages.userUnlockConfirmTitle'),
    content: (willLock ? pageText('pages.userLockConfirmContent') : pageText('pages.userUnlockConfirmContent'))
      .replace('{name}', record.username),
    okText: pageText('pages.userConfirm'),
    okType: willLock ? 'danger' : 'primary',
    cancelText: pageText('pages.userCancel'),
    onOk: async () => {
      const res = await request.post('/user/lock/', {
        username: record.username,
        status: willLock ? 'locked' : 'active'
      });
      if (res.code === 200) {
        message.success(willLock ? pageText('pages.userLockSuccess') : pageText('pages.userUnlockSuccess'));
        await fetchUsers();
      } else {
        message.error(res.message || pageText('pages.userOperationFailed'));
      }
    }
  });
};

onMounted(() => {
  fetchUsers();
});
</script>

<style scoped>
.user-action-disabled {
  color: var(--arl-text-color);
  opacity: 0.35;
  cursor: not-allowed;
}
</style>
